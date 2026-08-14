import Darwin
import Foundation

struct DevServerTerminationRequest: Sendable {
    let port: Int
    let rootPID: Int
    let rootParentPID: Int
    let rootCommand: String
    let listenerPIDs: Set<Int>
    let repositoryPath: String?

    init(server: DevServerSnapshot) {
        port = server.port
        rootPID = server.rootPID
        let root = server.processes.first(where: { $0.pid == server.rootPID })
        rootParentPID = root?.parentPID ?? 0
        rootCommand = root?.command ?? ""
        listenerPIDs = Set(server.listenerPIDs)
        repositoryPath = server.repositoryPath
    }
}

struct DevServerTerminationResult: Sendable {
    let signalledProcessCount: Int
    let survivorPIDs: [Int]
}

enum DevServerTerminationError: LocalizedError {
    case serverChanged
    case noProcesses
    case protectedService(ports: [Int])
    case signalFailed(pid: Int, code: Int32)

    var errorDescription: String? {
        switch self {
        case .serverChanged:
            "The live dev server changed after confirmation. Nothing was stopped; refresh and review it again."
        case .noProcesses:
            "That dev server is no longer running."
        case let .protectedService(ports):
            "This dev-server tree also owns a protected emulator or local-model listener on \(ports.map { ":\($0)" }.joined(separator: ", ")). Nothing was stopped."
        case let .signalFailed(pid, code):
            "Could not gracefully stop dev-server PID \(pid) (errno \(code))."
        }
    }
}

actor DevServerTerminationService {
    private let inspection = ProcessInspectionService()
    private let analyzer = AgentRuntimeAnalyzer()
    private let codexSessionMetadata = CodexSessionMetadataService()

    func terminate(
        request: DevServerTerminationRequest,
        workspaceRoot: URL
    ) async throws -> DevServerTerminationResult {
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
        let server = try Self.validatedServer(request: request, runtime: runtime)
        let processPIDs = Set(processTable.descendants(of: server.rootPID).map(\.pid))
        guard !processPIDs.isEmpty else { throw DevServerTerminationError.noProcesses }

        let protectedPorts = AgentCleanupService.protectedServicePortsOwned(
            by: processPIDs,
            listeningPorts: ports
        )
        guard protectedPorts.isEmpty else {
            throw DevServerTerminationError.protectedService(ports: protectedPorts)
        }

        let orderedPIDs = processPIDs.sorted {
            processDepth($0, within: processPIDs, table: processTable)
                > processDepth($1, within: processPIDs, table: processTable)
        }
        for pid in orderedPIDs where processTable.processes[pid] != nil {
            if Darwin.kill(pid_t(pid), 0) != 0 && errno != ESRCH {
                throw DevServerTerminationError.signalFailed(pid: pid, code: errno)
            }
        }

        var signalled = 0
        for pid in orderedPIDs where processTable.processes[pid] != nil {
            if Darwin.kill(pid_t(pid), SIGTERM) == 0 {
                signalled += 1
            } else if errno != ESRCH {
                throw DevServerTerminationError.signalFailed(pid: pid, code: errno)
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (afterTable, _) = try await inspection.capture()
        return DevServerTerminationResult(
            signalledProcessCount: signalled,
            survivorPIDs: processPIDs.filter { afterTable.processes[$0] != nil }.sorted()
        )
    }

    static func validatedServer(
        request: DevServerTerminationRequest,
        runtime: AgentRuntimeSnapshot
    ) throws -> DevServerSnapshot {
        guard let server = runtime.devServers.first(where: {
            $0.port == request.port && $0.rootPID == request.rootPID
        }),
        let root = server.processes.first(where: { $0.pid == server.rootPID }),
        !request.rootCommand.isEmpty,
        root.parentPID == request.rootParentPID,
        root.command == request.rootCommand,
        Set(server.listenerPIDs) == request.listenerPIDs,
        server.repositoryPath == request.repositoryPath else {
            throw DevServerTerminationError.serverChanged
        }
        return server
    }

    private func processDepth(_ pid: Int, within group: Set<Int>, table: ProcessTable) -> Int {
        var depth = 0
        var current = table.processes[pid]
        var seen: Set<Int> = []
        while let process = current,
              group.contains(process.parentPID),
              !seen.contains(process.pid) {
            seen.insert(process.pid)
            depth += 1
            current = table.processes[process.parentPID]
        }
        return depth
    }
}
