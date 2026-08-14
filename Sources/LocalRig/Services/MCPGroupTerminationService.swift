import Darwin
import Foundation

struct MCPInstanceIdentity: Hashable, Sendable {
    let rootPID: Int
    let rootCommand: String
    let sessionID: String?
}

struct MCPGroupTerminationRequest: Sendable {
    let name: String
    let kind: RuntimeComponentKind
    let instances: Set<MCPInstanceIdentity>

    init(usage: MCPUsageSnapshot, runtime: AgentRuntimeSnapshot) {
        name = usage.name
        kind = usage.kind
        var captured: Set<MCPInstanceIdentity> = []
        for session in runtime.sessions {
            for component in session.components where component.name == usage.name && component.kind == usage.kind {
                if let root = component.processes.first(where: { $0.pid == component.rootPID }) {
                    captured.insert(MCPInstanceIdentity(
                        rootPID: root.pid,
                        rootCommand: root.command,
                        sessionID: session.id
                    ))
                }
            }
        }
        for component in runtime.unassignedComponents where component.name == usage.name && component.kind == usage.kind {
            if let root = component.processes.first(where: { $0.pid == component.rootPID }) {
                captured.insert(MCPInstanceIdentity(
                    rootPID: root.pid,
                    rootCommand: root.command,
                    sessionID: nil
                ))
            }
        }
        instances = captured
    }
}

struct MCPGroupTerminationResult: Sendable {
    let signalledProcessCount: Int
    let survivorPIDs: [Int]
}

enum MCPGroupTerminationError: LocalizedError {
    case groupChanged
    case noInstances
    case protectedService(ports: [Int])
    case signalFailed(pid: Int, code: Int32)

    var errorDescription: String? {
        switch self {
        case .groupChanged:
            "The live MCP instances changed after confirmation. Nothing was stopped; refresh and review the group again."
        case .noInstances:
            "No matching MCP instances remain."
        case let .protectedService(ports):
            "This MCP group owns a protected Rig service on \(ports.map { ":\($0)" }.joined(separator: ", ")). Nothing was stopped."
        case let .signalFailed(pid, code):
            "Could not gracefully stop MCP PID \(pid) (errno \(code))."
        }
    }
}

actor MCPGroupTerminationService {
    private let inspection = ProcessInspectionService()
    private let analyzer = AgentRuntimeAnalyzer()
    private let codexSessionMetadata = CodexSessionMetadataService()

    func terminate(
        request: MCPGroupTerminationRequest,
        workspaceRoot: URL
    ) async throws -> MCPGroupTerminationResult {
        guard !request.instances.isEmpty else { throw MCPGroupTerminationError.noInstances }
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
        let currentRequest = MCPGroupTerminationRequest(
            usage: MCPUsageSnapshot(
                name: request.name,
                kind: request.kind,
                instanceCount: 0,
                processCount: 0,
                residentBytes: 0,
                cpuPercent: 0,
                sessionIDs: [],
                sessionTitles: []
            ),
            runtime: runtime
        )
        guard currentRequest.instances == request.instances else {
            throw MCPGroupTerminationError.groupChanged
        }

        var processPIDs: Set<Int> = []
        for identity in request.instances {
            processPIDs.formUnion(processTable.descendants(of: identity.rootPID).map(\.pid))
        }
        guard !processPIDs.isEmpty else { throw MCPGroupTerminationError.noInstances }
        let protectedPorts = AgentCleanupService.protectedServicePortsOwned(
            by: processPIDs,
            listeningPorts: ports
        )
        guard protectedPorts.isEmpty else {
            throw MCPGroupTerminationError.protectedService(ports: protectedPorts)
        }

        let orderedPIDs = processPIDs.sorted {
            processDepth($0, within: processPIDs, table: processTable)
                > processDepth($1, within: processPIDs, table: processTable)
        }
        for pid in orderedPIDs where processTable.processes[pid] != nil {
            if Darwin.kill(pid_t(pid), 0) != 0 && errno != ESRCH {
                throw MCPGroupTerminationError.signalFailed(pid: pid, code: errno)
            }
        }

        var signalled = 0
        for pid in orderedPIDs where processTable.processes[pid] != nil {
            if Darwin.kill(pid_t(pid), SIGTERM) == 0 {
                signalled += 1
            } else if errno != ESRCH {
                throw MCPGroupTerminationError.signalFailed(pid: pid, code: errno)
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (afterTable, _) = try await inspection.capture()
        return MCPGroupTerminationResult(
            signalledProcessCount: signalled,
            survivorPIDs: processPIDs.filter { afterTable.processes[$0] != nil }.sorted()
        )
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
