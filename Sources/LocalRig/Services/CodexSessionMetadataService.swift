import Foundation

struct CodexCohortMetadata: Sendable {
    let threadID: String
    let title: String?
    let isTurnActive: Bool
}

struct CodexTurnEvent: Sendable {
    enum Kind: Sendable {
        case started
        case ended
    }

    let date: Date
    let kind: Kind
}

struct CodexRolloutActivity: Sendable {
    let threadID: String
    let events: [CodexTurnEvent]

    var startDates: [Date] { events.filter { $0.kind == .started }.map(\.date) }
    var isTurnActive: Bool {
        guard let latest = events.max(by: { $0.date < $1.date }) else { return false }
        return latest.kind == .started
    }
}

actor CodexSessionMetadataService {
    private struct FileCache {
        var offset: UInt64
        var remainder: Data
        var events: [CodexTurnEvent]
    }

    private let sessionsDirectory: URL
    private let globalStateURL: URL
    private let matchTolerance: TimeInterval = 30
    private var fileCaches: [URL: FileCache] = [:]

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        sessionsDirectory = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        globalStateURL = codexDirectory.appendingPathComponent(".codex-global-state.json")
    }

    func metadataByCohortPID(
        processTable: ProcessTable,
        capturedAt: Date
    ) -> [Int: CodexCohortMetadata] {
        let cohorts = processTable.processes.values.filter {
            $0.command.lowercased().contains("node_repl")
        }
        guard !cohorts.isEmpty else { return [:] }

        let cohortStarts = Dictionary(uniqueKeysWithValues: cohorts.map {
            ($0.pid, capturedAt.addingTimeInterval(-TimeInterval(Self.elapsedSeconds($0.elapsed))))
        })
        let oldestStart = cohortStarts.values.min() ?? capturedAt
        let activities = rolloutActivities(
            modifiedAfter: oldestStart.addingTimeInterval(-matchTolerance)
        )
        let descriptions = loadThreadDescriptions()

        return Self.resolveMetadata(
            cohortStartsByPID: cohortStarts,
            activities: activities,
            threadDescriptions: descriptions,
            tolerance: matchTolerance
        )
    }

    static func resolveMetadata(
        cohortStartsByPID: [Int: Date],
        activities: [CodexRolloutActivity],
        threadDescriptions: [String: String],
        tolerance: TimeInterval = 30
    ) -> [Int: CodexCohortMetadata] {
        var resolved: [Int: CodexCohortMetadata] = [:]
        for (pid, startedAt) in cohortStartsByPID {
            let candidates = activities.filter { activity in
                activity.startDates.contains {
                    abs($0.timeIntervalSince(startedAt)) <= tolerance
                }
            }
            guard candidates.count == 1, let activity = candidates.first else { continue }
            resolved[pid] = CodexCohortMetadata(
                threadID: activity.threadID,
                title: sanitizedTitle(threadDescriptions[activity.threadID]),
                isTurnActive: activity.isTurnActive
            )
        }
        return resolved
    }

    private func rolloutActivities(modifiedAfter cutoff: Date) -> [CodexRolloutActivity] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var activities: [CodexRolloutActivity] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff,
                  let threadID = Self.threadID(from: file),
                  let events = updateEvents(for: file),
                  !events.isEmpty else { continue }
            activities.append(CodexRolloutActivity(threadID: threadID, events: events))
        }
        return activities
    }

    private func updateEvents(for file: URL) -> [CodexTurnEvent]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }

        var cache = fileCaches[file] ?? FileCache(offset: 0, remainder: Data(), events: [])
        if size < cache.offset {
            cache = FileCache(offset: 0, remainder: Data(), events: [])
        }
        guard size > cache.offset,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return cache.events
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: cache.offset)

        var buffer = cache.remainder
        while let chunk = try? handle.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                if let event = Self.turnEvent(from: Data(buffer[lineStart..<newline])) {
                    cache.events.append(event)
                }
                lineStart = buffer.index(after: newline)
            }
            buffer = Data(buffer[lineStart...])
        }
        cache.offset = size
        cache.remainder = buffer
        fileCaches[file] = cache
        return cache.events
    }

    private func loadThreadDescriptions() -> [String: String] {
        guard let data = try? Data(contentsOf: globalStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atomState = root["electron-persisted-atom-state"] as? [String: Any],
              let descriptions = atomState["thread-descriptions-v1"] as? [String: String] else {
            return [:]
        }
        return descriptions
    }

    private static func turnEvent(from data: Data) -> CodexTurnEvent? {
        let eventMarker = Data("event_msg".utf8)
        let lifecycleMarkers = ["task_started", "task_complete", "turn_aborted"]
            .map { Data($0.utf8) }
        guard data.range(of: eventMarker) != nil,
              lifecycleMarkers.contains(where: { data.range(of: $0) != nil }) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              let timestamp = object["timestamp"] as? String,
              let date = parseTimestamp(timestamp) else { return nil }

        switch payloadType {
        case "task_started":
            return CodexTurnEvent(date: date, kind: .started)
        case "task_complete", "turn_aborted":
            return CodexTurnEvent(date: date, kind: .ended)
        default:
            return nil
        }
    }

    private static func threadID(from file: URL) -> String? {
        let filename = file.deletingPathExtension().lastPathComponent
        let components = filename.split(separator: "-")
        guard components.count >= 5 else { return nil }
        let candidate = components.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate)?.uuidString.lowercased()
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func sanitizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(100))
    }

    private static func elapsedSeconds(_ elapsed: String) -> UInt64 {
        let dayParts = elapsed.split(separator: "-", maxSplits: 1)
        let days = dayParts.count == 2 ? UInt64(dayParts[0]) ?? 0 : 0
        let clock = dayParts.count == 2 ? dayParts[1] : Substring(elapsed)
        let values = clock.split(separator: ":").compactMap { UInt64($0) }
        switch values.count {
        case 3: return days * 86_400 + values[0] * 3_600 + values[1] * 60 + values[2]
        case 2: return days * 86_400 + values[0] * 60 + values[1]
        case 1: return days * 86_400 + values[0]
        default: return days * 86_400
        }
    }
}
