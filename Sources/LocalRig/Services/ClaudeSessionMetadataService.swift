import Foundation

struct ClaudeSessionMetadata: Sendable {
    let id: String
    let title: String
    let createdAt: Date
}

actor ClaudeSessionMetadataService {
    private let projectsDirectory: URL
    private let newSessionTolerance: TimeInterval = 15

    init(projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.projectsDirectory = projectsDirectory
    }

    func titlesByProcessID(
        processTable: ProcessTable,
        capturedAt: Date
    ) -> [Int: String] {
        let processes = processTable.processes.values.filter(Self.isClaudeCodeRuntime)
        guard !processes.isEmpty else { return [:] }

        let exactSessionIDs = Set(processes.compactMap {
            Self.resumeSessionID(in: $0.command)?.lowercased()
        })
        let newSessionStartTimes = processes.compactMap { process -> Date? in
            guard Self.resumeSessionID(in: process.command) == nil else { return nil }
            return capturedAt.addingTimeInterval(-TimeInterval(Self.elapsedSeconds(process.elapsed)))
        }
        let metadata = loadMetadata(
            exactSessionIDs: exactSessionIDs,
            newSessionStartTimes: newSessionStartTimes
        )
        return Self.resolveTitles(
            processes: processes,
            metadata: metadata,
            capturedAt: capturedAt,
            newSessionTolerance: newSessionTolerance
        )
    }

    static func resolveTitles(
        processes: [LocalProcess],
        metadata: [ClaudeSessionMetadata],
        capturedAt: Date,
        newSessionTolerance: TimeInterval = 15
    ) -> [Int: String] {
        var byID: [String: ClaudeSessionMetadata] = [:]
        for value in metadata {
            byID[value.id.lowercased()] = value
        }
        var resolved: [Int: String] = [:]

        for process in processes {
            if let sessionID = resumeSessionID(in: process.command)?.lowercased(),
               let exact = byID[sessionID] {
                resolved[process.pid] = exact.title
                continue
            }

            let startedAt = capturedAt.addingTimeInterval(-TimeInterval(elapsedSeconds(process.elapsed)))
            let candidates = metadata.filter {
                abs($0.createdAt.timeIntervalSince(startedAt)) <= newSessionTolerance
            }
            if candidates.count == 1, let candidate = candidates.first {
                resolved[process.pid] = candidate.title
            }
        }
        return resolved
    }

    static func resumeSessionID(in command: String) -> String? {
        let pattern = #"(?:^|\s)--resume(?:=|\s+)([0-9a-fA-F-]{36})(?:\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..<command.endIndex, in: command)
              ),
              let valueRange = Range(match.range(at: 1), in: command) else {
            return nil
        }
        let value = String(command[valueRange])
        return UUID(uuidString: value) == nil ? nil : value.lowercased()
    }

    private func loadMetadata(
        exactSessionIDs: Set<String>,
        newSessionStartTimes: [Date]
    ) -> [ClaudeSessionMetadata] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .creationDateKey]
        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [ClaudeSessionMetadata] = []
        for projectDirectory in projectDirectories {
            guard (try? projectDirectory.resourceValues(forKeys: keys).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: projectDirectory,
                      includingPropertiesForKeys: Array(keys),
                      options: [.skipsHiddenFiles]
                  ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)?.uuidString.lowercased(),
                      let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let createdAt = values.creationDate else { continue }
                let isRelevant = exactSessionIDs.contains(id)
                    || newSessionStartTimes.contains {
                        abs(createdAt.timeIntervalSince($0)) <= newSessionTolerance
                    }
                guard isRelevant,
                      let title = latestCustomTitle(in: file) else { continue }
                results.append(ClaudeSessionMetadata(id: id, title: title, createdAt: createdAt))
            }
        }
        return results
    }

    private func latestCustomTitle(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let maximumTailBytes: UInt64 = 256 * 1_024
        try? handle.seek(toOffset: length > maximumTailBytes ? length - maximumTailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let rawTitle = object["customTitle"] as? String,
                  let title = Self.sanitizedTitle(rawTitle) else { continue }
            return title
        }
        return nil
    }

    private static func sanitizedTitle(_ value: String) -> String? {
        let singleLine = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(100))
    }

    private static func isClaudeCodeRuntime(_ process: LocalProcess) -> Bool {
        process.command.hasPrefix("/Users/")
            && process.command.contains("/Library/Application Support/Claude/claude-code/")
            && process.command.contains("/claude.app/Contents/MacOS/claude")
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
