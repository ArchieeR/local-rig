import Darwin
import Foundation

struct AgentCleanupResult: Sendable {
    let sessionID: String
    let signalledProcessCount: Int
    let survivorPIDs: [Int]
    let reclaimedEstimateBytes: UInt64
}

enum AgentSessionTerminationKind: Sendable, Equatable {
    case staleCleanup
    case userRequested
}

struct AgentSessionTerminationRequest: Sendable {
    let sessionID: String
    let expectedFamily: AgentFamily
    let expectedTaskRuntimePIDs: Set<Int>
    let expectedTaskRuntimeCommands: [Int: String]
    let kind: AgentSessionTerminationKind

    init(session: AgentSessionGroup, kind: AgentSessionTerminationKind) {
        let taskPIDs = Set(session.taskRuntimePIDs)
        sessionID = session.id
        expectedFamily = session.family
        expectedTaskRuntimePIDs = taskPIDs
        expectedTaskRuntimeCommands = Dictionary(uniqueKeysWithValues:
            session.components
                .flatMap(\.processes)
                .filter { taskPIDs.contains($0.pid) }
                .map { ($0.pid, $0.command) }
        )
        self.kind = kind
    }
}

enum AgentCleanupError: LocalizedError {
    case sessionDisappeared
    case unsupportedAgent
    case noLongerStale
    case activeRuntimeDetected
    case sessionIdentityChanged
    case protectedSharedService(ports: [Int])
    case noProcesses
    case signalFailed(pid: Int, code: Int32)

    var errorDescription: String? {
        switch self {
        case .sessionDisappeared:
            "That cohort no longer exists. The dashboard has been refreshed."
        case .unsupportedAgent:
            "Rig can end Codex and Claude Code sessions, but not shared Claude Desktop application processes."
        case .noLongerStale:
            "That cohort no longer meets the stale-process rules. Nothing was stopped."
        case .activeRuntimeDetected:
            "A live Codex app-server reappeared in that cohort. Nothing was stopped."
        case .sessionIdentityChanged:
            "That session's live runtime identity changed after confirmation. Nothing was stopped; refresh and review it again."
        case let .protectedSharedService(ports):
            "That session currently owns a protected Rig emulator or local-model listener on \(ports.map { ":\($0)" }.joined(separator: ", ")). Stop or detach that service through Rig before ending the session."
        case .noProcesses:
            "No matching processes remain."
        case let .signalFailed(pid, code):
            "Could not gracefully stop PID \(pid) (errno \(code))."
        }
    }
}

actor AgentCleanupService {
    private let inspection = ProcessInspectionService()
    private let analyzer = AgentRuntimeAnalyzer()
    private let codexSessionMetadata = CodexSessionMetadataService()

    func terminateSession(
        request: AgentSessionTerminationRequest,
        workspaceRoot: URL
    ) async throws -> AgentCleanupResult {
        let (processTable, ports) = try await inspection.capture()
        let metadata = await codexSessionMetadata.metadataByCohortPID(
            processTable: processTable,
            capturedAt: Date()
        )
        let runtime = analyzer.analyze(
            processTable: processTable,
            listeningPorts: ports,
            workspaceRoot: workspaceRoot,
            codexSessionMetadataByPID: metadata
        )
        let session = try Self.validatedSession(request: request, runtime: runtime)
        let cohortPIDs = Self.terminationPIDs(session: session, processTable: processTable)
        guard !cohortPIDs.isEmpty else { throw AgentCleanupError.noProcesses }
        let protectedPorts = Self.protectedServicePortsOwned(
            by: cohortPIDs,
            listeningPorts: ports
        )
        guard protectedPorts.isEmpty else {
            throw AgentCleanupError.protectedSharedService(ports: protectedPorts)
        }

        let orderedPIDs = cohortPIDs.sorted {
            processDepth($0, within: cohortPIDs, table: processTable)
                > processDepth($1, within: cohortPIDs, table: processTable)
        }
        // Verify the whole cohort is signalable before changing any process state.
        // ESRCH is harmless here because a process may exit between capture and cleanup.
        for pid in orderedPIDs where processTable.processes[pid] != nil {
            if Darwin.kill(pid_t(pid), 0) != 0 && errno != ESRCH {
                throw AgentCleanupError.signalFailed(pid: pid, code: errno)
            }
        }

        var signalledProcessCount = 0
        for pid in orderedPIDs {
            guard processTable.processes[pid] != nil else { continue }
            if Darwin.kill(pid_t(pid), SIGTERM) == 0 {
                signalledProcessCount += 1
            } else if errno != ESRCH {
                throw AgentCleanupError.signalFailed(pid: pid, code: errno)
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (afterTable, _) = try await inspection.capture()
        let survivors = cohortPIDs.filter { afterTable.processes[$0] != nil }.sorted()
        return AgentCleanupResult(
            sessionID: request.sessionID,
            signalledProcessCount: signalledProcessCount,
            survivorPIDs: survivors,
            reclaimedEstimateBytes: session.residentBytes
        )
    }

    static func validatedSession(
        request: AgentSessionTerminationRequest,
        runtime: AgentRuntimeSnapshot
    ) throws -> AgentSessionGroup {
        guard let session = runtime.sessions.first(where: { $0.id == request.sessionID }) else {
            throw AgentCleanupError.sessionDisappeared
        }
        guard session.family == request.expectedFamily,
              !request.expectedTaskRuntimePIDs.isEmpty,
              Set(session.taskRuntimePIDs) == request.expectedTaskRuntimePIDs,
              taskRuntimeCommands(in: session) == request.expectedTaskRuntimeCommands else {
            throw AgentCleanupError.sessionIdentityChanged
        }

        switch request.kind {
        case .staleCleanup:
            guard session.family == .codex else { throw AgentCleanupError.unsupportedAgent }
            guard session.isStaleCandidate else { throw AgentCleanupError.noLongerStale }
            guard session.activeSessionCount == 0,
                  !session.components.flatMap(\.processes).contains(where: {
                      $0.command.contains("codex app-server")
                  }) else {
                throw AgentCleanupError.activeRuntimeDetected
            }
        case .userRequested:
            guard session.family == .codex || session.family == .claudeCode else {
                throw AgentCleanupError.unsupportedAgent
            }
        }
        return session
    }

    static func terminationPIDs(
        session: AgentSessionGroup,
        processTable: ProcessTable
    ) -> Set<Int> {
        var pids = Set(session.components.flatMap { $0.processes.map(\.pid) })
        for rootPID in session.taskRuntimePIDs {
            pids.formUnion(processTable.descendants(of: rootPID).map(\.pid))
        }
        return pids
    }

    static func protectedServicePortsOwned(
        by cohortPIDs: Set<Int>,
        listeningPorts: ListeningPorts
    ) -> [Int] {
        let emulatorBases = [4_000, 5_001, 8_080, 9_099, 9_199]
        let emulatorPorts = emulatorBases.flatMap { base in
            (0..<5).map { base + ($0 * 10) }
        }
        return (emulatorPorts + [11_435]).filter { port in
            !listeningPorts.processIDs(on: port).isDisjoint(with: cohortPIDs)
        }.sorted()
    }

    private static func taskRuntimeCommands(in session: AgentSessionGroup) -> [Int: String] {
        let taskPIDs = Set(session.taskRuntimePIDs)
        return Dictionary(uniqueKeysWithValues:
            session.components
                .flatMap(\.processes)
                .filter { taskPIDs.contains($0.pid) }
                .map { ($0.pid, $0.command) }
        )
    }

    private func processDepth(_ pid: Int, within cohort: Set<Int>, table: ProcessTable) -> Int {
        var depth = 0
        var current = table.processes[pid]
        var seen: Set<Int> = []
        while let process = current,
              cohort.contains(process.parentPID),
              !seen.contains(process.pid) {
            seen.insert(process.pid)
            depth += 1
            current = table.processes[process.parentPID]
        }
        return depth
    }
}
