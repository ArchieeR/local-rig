import AppKit
import Foundation
import OSLog

struct AgentHandoffResult: Sendable {
    let url: URL
    let prompt: String
    let title: String
    let summary: String

    init(url: URL, prompt: String, title: String = "Agent handoff ready", summary: String = "A bounded, redacted log bundle was written to disk. The ready-to-paste prompt is on your clipboard.") {
        self.url = url
        self.prompt = prompt
        self.title = title
        self.summary = summary
    }
}

private struct AgentReadableSnapshot: Codable {
    struct RuntimeComponent: Codable {
        let rootPID: Int
        let name: String
        let kind: String
        let processCount: Int
        let nodeProcessCount: Int
        let residentBytes: UInt64
        let cpuPercent: Double
        let repositoryPath: String?
        let listeningPorts: [Int]
        let staleReasons: [String]
    }

    struct Session: Codable {
        let id: String
        let family: String
        let title: String
        let activeSessionCount: Int
        let inactiveSessionCount: Int
        let ageSeconds: UInt64
        let repositoryPaths: [String]
        let residentBytes: UInt64
        let cpuPercent: Double
        let staleReasons: [String]
        let components: [RuntimeComponent]
    }

    struct DevServer: Codable {
        let port: Int
        let rootPID: Int
        let listenerPIDs: [Int]
        let processCount: Int
        let repositoryPath: String?
        let ownerKind: String
        let ownerLabel: String
        let sessionID: String?
        let ageSeconds: UInt64
        let residentBytes: UInt64
        let cpuPercent: Double
    }

    struct MCPUsage: Codable {
        let name: String
        let kind: String
        let instanceCount: Int
        let processCount: Int
        let sessionCount: Int
        let sessionTitles: [String]
        let residentBytes: UInt64
        let cpuPercent: Double
    }

    struct Runtime: Codable {
        let estimatedSessionCount: Int
        let activeSessionCount: Int
        let mcpCount: Int
        let nodeProcessCount: Int
        let residentBytes: UInt64
        let staleCandidateCount: Int
        let sessions: [Session]
        let unassignedComponents: [RuntimeComponent]
        let devServers: [DevServer]
        let mcpUsageByType: [MCPUsage]
    }

    struct Rig: Codable {
        let id: Int
        let holder: String?
        let mode: String
        let profile: String
        let controller: String
        let repository: RepositoryIdentity
        let backendRepository: RepositoryIdentity
        let services: [RigServiceStatus]
        let devResidentBytes: UInt64
        let emulatorResidentBytes: UInt64
        let devLogPath: String
        let emulatorLogPath: String
        let redactedDevLogTail: String
        let redactedEmulatorLogTail: String
    }

    struct LocalModel: Codable {
        let model: String
        let profile: String
        let featureProfile: String
        let status: String
        let endpoint: String
        let processPID: Int?
        let residentBytes: UInt64
        let modelFileBytes: UInt64
        let requiredArtifactCount: Int
        let downloadedArtifactCount: Int
        let requestsProcessing: Int
        let promptTokensPerSecond: Double?
        let predictedTokensPerSecond: Double?
        let logPath: String
        let redactedLogTail: String
    }

    let schemaVersion: Int
    let capturedAt: Date
    let workspaceRoot: String
    let systemMemory: SystemMemorySnapshot
    let rigs: [Rig]
    let agentRuntime: Runtime
    let localModel: LocalModel
}

struct AgentArtifactWriter: Sendable {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.localrig.LocalRig", category: "AgentHandoff")

    func writeCurrent(snapshot: DashboardSnapshot) throws -> URL {
        let directory = artifactDirectory(workspaceRoot: URL(fileURLWithPath: snapshot.workspaceRoot))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("current.json")
        let payload = AgentReadableSnapshot(
            schemaVersion: 8,
            capturedAt: snapshot.capturedAt,
            workspaceRoot: snapshot.workspaceRoot,
            systemMemory: snapshot.systemMemory,
            rigs: snapshot.rigs.map { rig in
                AgentReadableSnapshot.Rig(
                    id: rig.id,
                    holder: rig.holder,
                    mode: rig.mode.rawValue,
                    profile: rig.profile.rawValue,
                    controller: rig.controller.rawValue,
                    repository: rig.repository,
                    backendRepository: rig.backendRepository,
                    services: rig.services,
                    devResidentBytes: rig.devResidentBytes,
                    emulatorResidentBytes: rig.emulatorResidentBytes,
                    devLogPath: rig.devLogPath,
                    emulatorLogPath: rig.emulatorLogPath,
                    redactedDevLogTail: LogSanitizer.sanitize(rig.devLogTail, maximumLines: 80),
                    redactedEmulatorLogTail: LogSanitizer.sanitize(rig.emulatorLogTail, maximumLines: 80)
                )
            },
            agentRuntime: readableRuntime(snapshot.agentRuntime),
            localModel: AgentReadableSnapshot.LocalModel(
                model: snapshot.localModel.selectedModel.rawValue,
                profile: snapshot.localModel.profile.rawValue,
                featureProfile: snapshot.localModel.featureProfile.rawValue,
                status: snapshot.localModel.status.rawValue,
                endpoint: snapshot.localModel.endpoint,
                processPID: snapshot.localModel.processPID,
                residentBytes: snapshot.localModel.residentBytes,
                modelFileBytes: snapshot.localModel.modelFileBytes,
                requiredArtifactCount: snapshot.localModel.requiredArtifactCount,
                downloadedArtifactCount: snapshot.localModel.downloadedArtifactCount,
                requestsProcessing: snapshot.localModel.requestsProcessing,
                promptTokensPerSecond: snapshot.localModel.promptTokensPerSecond,
                predictedTokensPerSecond: snapshot.localModel.predictedTokensPerSecond,
                logPath: snapshot.localModel.logPath,
                redactedLogTail: snapshot.localModel.redactedLogTail
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: url, options: .atomic)
        return url
    }

    private func readableRuntime(_ runtime: AgentRuntimeSnapshot) -> AgentReadableSnapshot.Runtime {
        func component(_ value: RuntimeComponent) -> AgentReadableSnapshot.RuntimeComponent {
            AgentReadableSnapshot.RuntimeComponent(
                rootPID: value.rootPID,
                name: value.name,
                kind: value.kind.rawValue,
                processCount: value.processes.count,
                nodeProcessCount: value.nodeProcessCount,
                residentBytes: value.residentBytes,
                cpuPercent: value.cpuPercent,
                repositoryPath: value.repositoryPath,
                listeningPorts: value.listeningPorts,
                staleReasons: value.staleReasons
            )
        }
        return AgentReadableSnapshot.Runtime(
            estimatedSessionCount: runtime.estimatedSessionCount,
            activeSessionCount: runtime.activeSessionCount,
            mcpCount: runtime.mcpCount,
            nodeProcessCount: runtime.nodeProcessCount,
            residentBytes: runtime.residentBytes,
            staleCandidateCount: runtime.staleCandidateCount,
            sessions: runtime.sessions.map { session in
                AgentReadableSnapshot.Session(
                    id: session.id,
                    family: session.family.rawValue,
                    title: session.title,
                    activeSessionCount: session.activeSessionCount,
                    inactiveSessionCount: session.inactiveSessionCount,
                    ageSeconds: session.ageSeconds,
                    repositoryPaths: session.repositoryPaths,
                    residentBytes: session.residentBytes,
                    cpuPercent: session.cpuPercent,
                    staleReasons: session.staleReasons,
                    components: session.components.map(component)
                )
            },
            unassignedComponents: runtime.unassignedComponents.map(component),
            devServers: runtime.devServers.map { server in
                AgentReadableSnapshot.DevServer(
                    port: server.port,
                    rootPID: server.rootPID,
                    listenerPIDs: server.listenerPIDs,
                    processCount: server.processes.count,
                    repositoryPath: server.repositoryPath,
                    ownerKind: server.ownerKind.rawValue,
                    ownerLabel: server.ownerLabel,
                    sessionID: server.sessionID,
                    ageSeconds: server.ageSeconds,
                    residentBytes: server.residentBytes,
                    cpuPercent: server.cpuPercent
                )
            },
            mcpUsageByType: runtime.mcpUsageByType.map { usage in
                AgentReadableSnapshot.MCPUsage(
                    name: usage.name,
                    kind: usage.kind.rawValue,
                    instanceCount: usage.instanceCount,
                    processCount: usage.processCount,
                    sessionCount: usage.sessionCount,
                    sessionTitles: usage.sessionTitles,
                    residentBytes: usage.residentBytes,
                    cpuPercent: usage.cpuPercent
                )
            }
        )
    }

    func createHandoff(
        snapshot: DashboardSnapshot,
        rig: RigSnapshot,
        commandOutput: String?
    ) throws -> AgentHandoffResult {
        let directory = artifactDirectory(workspaceRoot: URL(fileURLWithPath: snapshot.workspaceRoot))
            .appendingPathComponent("handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(RigFormatters.handoffTimestamp(Date()))-rig\(rig.id).md"
        let url = directory.appendingPathComponent(filename)
        let latestURL = directory.appendingPathComponent("latest.md")
        let markdown = renderHandoff(snapshot: snapshot, rig: rig, commandOutput: commandOutput)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try markdown.write(to: latestURL, atomically: true, encoding: .utf8)

        let prompt = "Please diagnose Rig \(rig.id) using the generated handoff at \(url.path). Read the referenced raw logs only if needed. Do not start, stop, reset, or repoint processes unless I explicitly ask."
        logger.info("Created redacted handoff for rig \(rig.id, privacy: .public)")
        return AgentHandoffResult(url: url, prompt: prompt)
    }

    private func renderHandoff(
        snapshot: DashboardSnapshot,
        rig: RigSnapshot,
        commandOutput: String?
    ) -> String {
        let services = rig.services.map { service in
            "- \(service.kind.rawValue): \(service.isListening ? "listening" : "down") on :\(service.port)\(service.isShared ? " (shared from Rig 1)" : "")"
        }.joined(separator: "\n")
        let devLog = indented(LogSanitizer.sanitize(rig.devLogTail))
        let emulatorLog = indented(LogSanitizer.sanitize(rig.emulatorLogTail))
        let command = indented(LogSanitizer.sanitize(commandOutput ?? "No dashboard command output captured.", maximumLines: 120))

        return """
        # Local Rig agent handoff — Rig \(rig.id)

        Generated: \(ISO8601DateFormatter().string(from: snapshot.capturedAt))

        ## Runtime

        - Controller: `\(rig.controller.rawValue)`
        - Mode: `\(rig.mode.rawValue)`
        - Profile: `\(rig.profile.rawValue)`
        - Holder: \(rig.holder ?? "free")
        - Dev RAM estimate: \(RigFormatters.memory(rig.devResidentBytes))
        - Emulator RAM estimate: \(RigFormatters.memory(rig.emulatorResidentBytes))
        - Physical memory occupied: \(RigFormatters.memory(snapshot.systemMemory.physicalOccupiedBytes)) of \(RigFormatters.memory(snapshot.systemMemory.totalBytes))
        - Physical memory unused: \(RigFormatters.memory(snapshot.systemMemory.physicalUnusedBytes))
        - Wired / compressed: \(RigFormatters.memory(snapshot.systemMemory.wiredBytes)) / \(RigFormatters.memory(snapshot.systemMemory.compressedBytes))
        - Memory pressure: \(snapshot.systemMemory.pressureStatus) (reserve score \(String(format: "%.0f", snapshot.systemMemory.pressureReservePercentage))%)

        ## Dashboard worktree

        - Path: `\(rig.repository.path)`
        - Revision: `\(rig.repository.displayRevision)`
        - Commit: `\(rig.repository.commit ?? "unknown")` — \(rig.repository.summary ?? "")

        ## Backend worktree

        - Path: `\(rig.backendRepository.path)`
        - Revision: `\(rig.backendRepository.displayRevision)`
        - Commit: `\(rig.backendRepository.commit ?? "unknown")` — \(rig.backendRepository.summary ?? "")

        ## Services

        \(services)

        ## Log sources

        - Dev: `\(rig.devLogPath)`
        - Emulator: `\(rig.emulatorLogPath)`
        - Full-observability reminder: also inspect the filtered Firefox console/network evidence and persisted emulator state when diagnosing app behavior.

        ## Redacted dev log tail

        \(devLog)

        ## Redacted emulator log tail

        \(emulatorLog)

        ## Last dashboard command

        \(command)

        ## Safety boundary

        This handoff is diagnostic evidence, not authority to start, stop, reset, repoint, or write production data. Local MCP remains blocked because its stdio path can target production Firestore.
        """
    }

    private func artifactDirectory(workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(".rig-dashboard", isDirectory: true)
    }

    private func indented(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }
}

actor AgentArtifactWriteCoordinator {
    private let writer: AgentArtifactWriter
    private var latestAcceptedCapture: Date?

    init(writer: AgentArtifactWriter = AgentArtifactWriter()) {
        self.writer = writer
    }

    func writeCurrent(snapshot: DashboardSnapshot) throws -> URL? {
        if let latestAcceptedCapture,
           snapshot.capturedAt <= latestAcceptedCapture {
            return nil
        }

        let previousCapture = latestAcceptedCapture
        latestAcceptedCapture = snapshot.capturedAt
        do {
            return try writer.writeCurrent(snapshot: snapshot)
        } catch {
            latestAcceptedCapture = previousCapture
            throw error
        }
    }
}

@MainActor
enum PasteboardService {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
