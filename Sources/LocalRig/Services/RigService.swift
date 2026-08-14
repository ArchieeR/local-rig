import Foundation

actor RigService {
    private let runner = ProcessRunner()
    private let inspection = ProcessInspectionService()
    private let logTail = LogTailService()
    private let runtimeAnalyzer = AgentRuntimeAnalyzer()
    private let codexSessionMetadata = CodexSessionMetadataService()
    private let claudeSessionMetadata = ClaudeSessionMetadataService()
    private var repositoryCache: [String: (capturedAt: Date, identity: RepositoryIdentity)] = [:]

    func snapshot(workspaceRoot root: URL, rig2ControlsEnabled: Bool) async throws -> DashboardSnapshot {
        async let inspectionResult = inspection.capture()
        async let memoryResult = systemMemory()
        let (processTable, ports) = try await inspectionResult
        let memory = try await memoryResult
        let capturedAt = Date()
        let codexMetadata = await codexSessionMetadata.metadataByCohortPID(
            processTable: processTable,
            capturedAt: capturedAt
        )
        let claudeSessionTitles = await claudeSessionMetadata.titlesByProcessID(
            processTable: processTable,
            capturedAt: capturedAt
        )
        let agentRuntime = runtimeAnalyzer.analyze(
            processTable: processTable,
            listeningPorts: ports,
            workspaceRoot: root,
            codexSessionMetadataByPID: codexMetadata,
            claudeSessionTitlesByPID: claudeSessionTitles
        )
        let localModel = await LocalModelService.shared.snapshot(
            processTable: processTable,
            listeningPorts: ports
        )

        var rigs: [RigSnapshot] = []
        for index in 1...5 {
            let controller: RigController = index == 1 && !rig2ControlsEnabled ? .legacy : .rig2
            rigs.append(await rigSnapshot(
                index: index,
                controller: controller,
                root: root,
                processTable: processTable,
                listeningPorts: ports
            ))
        }

        return DashboardSnapshot(
            capturedAt: capturedAt,
            workspaceRoot: root.path,
            rig2IsVerified: FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".rig2/VERIFIED").path
            ),
            systemMemory: memory,
            rigs: rigs,
            agentRuntime: agentRuntime,
            localModel: localModel
        )
    }

    private func rigSnapshot(
        index: Int,
        controller: RigController,
        root: URL,
        processTable: ProcessTable,
        listeningPorts: ListeningPorts
    ) async -> RigSnapshot {
        let state = stateDirectory(index: index, controller: controller, root: root)
        let mode = readStateFile(state.appendingPathComponent(controller == .legacy ? "mode" : "mode"))
            .flatMap(RigMode.init(rawValue:)) ?? .shared
        let profile = readStateFile(state.appendingPathComponent("profile"))
            .flatMap(RigProfile.init(rawValue:)) ?? .real
        let holderFilename = controller == .legacy ? "lock" : "claim"
        let holder = readStateFile(state.appendingPathComponent(holderFilename))

        let defaultCheckout = root.appendingPathComponent(index == 1 ? "wt-qa-rig" : "wt-rig\(index)")
        let defaultBackend = root.appendingPathComponent("rheos-backend")
        let checkout = controller == .rig2
            ? Self.boundDirectory(state.appendingPathComponent("dashboard-root"), fallback: defaultCheckout)
            : defaultCheckout
        let backend = controller == .rig2
            ? Self.boundDirectory(state.appendingPathComponent("backend-root"), fallback: defaultBackend)
            : defaultBackend
        let repository = await repositoryIdentity(at: checkout)
        let backendRepository = await repositoryIdentity(at: backend)
        let servicePorts = portsForRig(index: index, mode: mode)

        let statuses = servicePorts.map { kind, port in
            let processIDs = listeningPorts.processIDs(on: port)
            return RigServiceStatus(
                kind: kind,
                port: port,
                isListening: !processIDs.isEmpty,
                processes: processIDs.compactMap { processTable.processes[$0] }.sorted { $0.pid < $1.pid },
                isShared: index > 1 && mode == .shared && kind != .dev
            )
        }.sorted { serviceOrder($0.kind) < serviceOrder($1.kind) }

        let devPort = 2_999 + index
        var devRootPIDs = listeningPorts.processIDs(on: devPort)
        if let pid = readPID(state.appendingPathComponent("dev.pid")), processTable.processes[pid] != nil {
            devRootPIDs.insert(pid)
        }

        var emulatorRootPIDs: Set<Int> = []
        for (kind, port) in servicePorts where kind != .dev {
            emulatorRootPIDs.formUnion(listeningPorts.processIDs(on: port))
        }
        let emulatorState = Self.emulatorStateDirectory(index: index, mode: mode, state: state, root: root)
        if let pid = readPID(emulatorState.appendingPathComponent("emu.pid")), processTable.processes[pid] != nil {
            emulatorRootPIDs.insert(pid)
        }

        let devLog = state.appendingPathComponent("dev.log").path
        let emulatorLog = emulatorState.appendingPathComponent("emu.log").path
        return RigSnapshot(
            id: index,
            holder: holder,
            mode: mode,
            profile: profile,
            controller: controller,
            repository: repository,
            backendRepository: backendRepository,
            services: statuses,
            devResidentBytes: processTable.residentBytes(rootPIDs: devRootPIDs),
            emulatorResidentBytes: processTable.residentBytes(rootPIDs: emulatorRootPIDs),
            devLogPath: devLog,
            emulatorLogPath: emulatorLog,
            devLogTail: logTail.read(path: devLog),
            emulatorLogTail: logTail.read(path: emulatorLog)
        )
    }

    private func portsForRig(index: Int, mode: RigMode) -> [(RigServiceKind, Int)] {
        let offset = (index - 1) * 10
        let emulatorOffset = index == 1 || mode == .isolated ? offset : 0
        return [
            (.dev, 2_999 + index),
            (.firestore, 8_080 + emulatorOffset),
            (.auth, 9_099 + emulatorOffset),
            (.functions, 5_001 + emulatorOffset),
            (.storage, 9_199 + emulatorOffset),
            (.emulatorUI, 4_000 + emulatorOffset),
        ]
    }

    private func serviceOrder(_ kind: RigServiceKind) -> Int {
        RigServiceKind.allCases.firstIndex(of: kind) ?? .max
    }

    private func stateDirectory(index: Int, controller: RigController, root: URL) -> URL {
        switch controller {
        case .legacy:
            root.appendingPathComponent(".qa-rig", isDirectory: true)
        case .rig2:
            root.appendingPathComponent(".rig2/\(index)", isDirectory: true)
        }
    }

    private func readStateFile(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.nilIfBlank
    }

    private func readPID(_ url: URL) -> Int? {
        readStateFile(url).flatMap(Int.init)
    }

    static func boundDirectory(_ stateFile: URL, fallback: URL) -> URL {
        guard let path = (try? String(contentsOf: stateFile, encoding: .utf8))?.nilIfBlank else { return fallback }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func emulatorStateDirectory(index: Int, mode: RigMode, state: URL, root: URL) -> URL {
        index > 1 && mode == .shared
            ? root.appendingPathComponent(".rig2/1", isDirectory: true)
            : state
    }

    private func repositoryIdentity(at url: URL) async -> RepositoryIdentity {
        if let cached = repositoryCache[url.path], Date().timeIntervalSince(cached.capturedAt) < 20 {
            return cached.identity
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            let identity = RepositoryIdentity(path: url.path, exists: false, branch: nil, commit: nil, summary: nil)
            repositoryCache[url.path] = (Date(), identity)
            return identity
        }

        async let branchResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", url.path, "symbolic-ref", "--short", "-q", "HEAD"]
        )
        async let commitResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", url.path, "log", "-1", "--format=%h%x1f%s"]
        )

        let branch = try? await branchResult
        let commit = try? await commitResult
        let commitParts = commit?.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1F}", maxSplits: 1)
        let identity = RepositoryIdentity(
            path: url.path,
            exists: true,
            branch: branch?.standardOutput.nilIfBlank,
            commit: commitParts?.first.map(String.init),
            summary: commitParts.flatMap { $0.count > 1 ? String($0[1]) : nil }
        )
        repositoryCache[url.path] = (Date(), identity)
        return identity
    }

    private func systemMemory() async throws -> SystemMemorySnapshot {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/memory_pressure"),
            arguments: []
        )
        return Self.parseSystemMemory(
            result.combinedOutput,
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    static func parseSystemMemory(_ output: String, totalBytes: UInt64) -> SystemMemorySnapshot {
        let pageSize = UInt64(capture(#"page size of\s+([0-9]+)"#, in: output) ?? "") ?? 16_384
        let freePages = UInt64(capture(#"Pages free:\s*([0-9]+)"#, in: output) ?? "") ?? 0
        let speculativePages = UInt64(capture(#"Pages speculative:\s*([0-9]+)"#, in: output) ?? "") ?? 0
        let wiredPages = UInt64(capture(#"Pages wired down:\s*([0-9]+)"#, in: output) ?? "") ?? 0
        let compressorPages = UInt64(capture(#"Pages used by compressor:\s*([0-9]+)"#, in: output) ?? "") ?? 0
        let reserve = Double(capture(#"free percentage:\s*([0-9]+(?:\.[0-9]+)?)%"#, in: output) ?? "") ?? 0

        let unusedBytes = min(totalBytes, (freePages + speculativePages) * pageSize)
        return SystemMemorySnapshot(
            totalBytes: totalBytes,
            physicalOccupiedBytes: totalBytes - unusedBytes,
            physicalUnusedBytes: unusedBytes,
            wiredBytes: wiredPages * pageSize,
            compressedBytes: compressorPages * pageSize,
            pressureReservePercentage: reserve
        )
    }

    private static func capture(_ pattern: String, in output: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[valueRange])
    }
}
