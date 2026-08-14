import XCTest
@testable import LocalRig

final class RigParsingTests: XCTestCase {
    func testProcessTableParsesAndAggregatesDescendants() {
        let output = """
         100   1 1024 1.5 01:00 node next dev
         101 100  512 0.2 00:59 next-server
         200   1 2048 0.0 02:00 java firebase
        """

        let table = ProcessTable.parse(output)

        XCTAssertEqual(table.processes[100]?.command, "node next dev")
        XCTAssertEqual(table.processes[100]?.cpuPercent, 1.5)
        XCTAssertEqual(table.processTree(rootPIDs: [100]).map(\.pid), [100, 101])
        XCTAssertEqual(table.residentBytes(rootPIDs: [100]), 1_536 * 1_024)
    }

    func testAgentRuntimeAnalyzerAttributesCodexCohortAndMCP() {
        let output = """
         100   1 5000 1.0 01:00 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
         110 100 1000 0.0 00:30 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
         111 100 2000 0.0 00:30 npm exec @mozilla/firefox-devtools-mcp@latest --headless
         112 111 3000 0.1 00:29 node /tmp/firefox-devtools-mcp
         113 100 1800 0.0 00:30 npm exec tsx --env-file=.env.mcp src/mcp/stdio.ts
         114 100 1900 0.0 00:30 npm exec tsx --env-file=.env.local src/mcp/stdio.ts
         120 110 1500 0.0 00:28 codex sandbox --working-dir /workspace/wt-onboarding
         121 110 2500 0.2 00:28 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
         900   1 9000 0.0 04:00 /Applications/Firefox.app/Contents/MacOS/firefox
         901 900 8000 0.0 03:59 /Applications/Firefox.app/Contents/MacOS/plugin-container /tmp/rust_mozprofile-personal-looking
        """
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        )

        XCTAssertEqual(runtime.estimatedSessionCount, 1)
        XCTAssertEqual(runtime.activeSessionCount, 1)
        XCTAssertEqual(runtime.mcpCount, 3)
        XCTAssertEqual(runtime.staleCandidateCount, 0)
        XCTAssertEqual(runtime.sessions.first?.repositoryPaths, ["/workspace/wt-onboarding"])
        XCTAssertEqual(runtime.sessions.first?.components.first(where: { $0.name == "Firefox DevTools" })?.processes.count, 2)
        XCTAssertEqual(runtime.mcpUsageByType.first?.name, "Firefox DevTools")
        XCTAssertEqual(runtime.mcpUsageByType.first?.residentBytes, 5_000 * 1_024)
        let firefoxUsage = try! XCTUnwrap(runtime.mcpUsageByType.first(where: { $0.name == "Firefox DevTools" }))
        let firefoxRequest = MCPGroupTerminationRequest(usage: firefoxUsage, runtime: runtime)
        XCTAssertEqual(firefoxRequest.instances.map(\.rootPID), [111])
        XCTAssertFalse(runtime.sessions.flatMap(\.components).flatMap(\.processes).contains { $0.pid == 900 || $0.pid == 901 })
        let activeSession = runtime.sessions[0]
        XCTAssertNoThrow(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: activeSession, kind: .userRequested),
            runtime: runtime
        ))
        XCTAssertThrowsError(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: activeSession, kind: .staleCleanup),
            runtime: runtime
        ))
    }

    func testDevServerInventoryFindsRigAgentClaudeDesktopAndTerminalServers() {
        let output = """
         100   1 5000 0.0 10:00 /Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled
         110 100 1000 0.0 09:59 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
         130 110 1200 0.0 09:58 npm run dev
         131 130 4000 0.2 09:57 node /workspace/agent-site/node_modules/.bin/next dev
         200   1 1000 0.0 08:00 npm exec next dev -p 3000
         201 200 3000 0.1 07:59 next-server (v16.1.6)
         400   1 2000 0.0 07:00 /Applications/Claude.app/Contents/MacOS/Claude
         410 400  500 0.0 06:59 /Applications/Claude.app/Contents/Helpers/disclaimer /usr/bin/npm --prefix site run dev
         411 410 1000 0.0 06:58 node /workspace/site/node_modules/.bin/next dev
         412 411 3000 0.1 06:57 next-server (v16.1.6)
         500   1  500 0.0 05:00 -zsh
         510 500 1000 0.0 04:59 npm run dev
         511 510 2500 0.1 04:58 node /Users/test/content-loop/node_modules/.bin/vite
        """
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [
                3_000: [201],
                3_016: [412],
                3_101: [131],
                5_179: [511],
            ]),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        )

        XCTAssertEqual(runtime.devServers.map(\.port), [3_000, 3_016, 3_101, 5_179])
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 3_000 })?.ownerLabel, "Rig 1 · reserved port")
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 3_016 })?.ownerKind, .claudeDesktop)
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 3_016 })?.repositoryPath, "/workspace/site")
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 3_101 })?.sessionID, "codex-100-110")
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 5_179 })?.ownerKind, .terminal)
        XCTAssertEqual(runtime.devServers.first(where: { $0.port == 5_179 })?.repositoryPath, "/Users/test/content-loop")
    }

    func testDevServerTerminationRequiresExactLiveRootCommand() throws {
        func runtime(command: String) -> AgentRuntimeSnapshot {
            AgentRuntimeAnalyzer().analyze(
                processTable: .parse("""
                 500   1  500 0.0 05:00 -zsh
                 510 500 1000 0.0 04:59 \(command)
                 511 510 2500 0.1 04:58 node /Users/test/content-loop/node_modules/.bin/vite
                """),
                listeningPorts: .init(processIDsByPort: [5_179: [511]]),
                workspaceRoot: URL(fileURLWithPath: "/workspace")
            )
        }

        let originalRuntime = runtime(command: "npm run dev")
        let server = try XCTUnwrap(originalRuntime.devServers.first)
        let request = DevServerTerminationRequest(server: server)
        XCTAssertNoThrow(try DevServerTerminationService.validatedServer(
            request: request,
            runtime: originalRuntime
        ))
        XCTAssertThrowsError(try DevServerTerminationService.validatedServer(
            request: request,
            runtime: runtime(command: "pnpm dev")
        ))
    }

    func testAgentRuntimeAnalyzerFlagsInactiveCohortAndOrphanDevHelper() {
        let output = """
         200   1 5000 0.0 30:00 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
         210 200 1000 0.0 20:00 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
         211 200 2000 0.0 20:00 node /workspace/local-rig/mcp/server.mjs
         300   1 4000 0.0 15:00 node /workspace/rheos-backend/node_modules/.bin/firebase-functions /workspace/rheos-backend
        """
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        )

        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertTrue(runtime.sessions[0].isStaleCandidate)
        XCTAssertEqual(runtime.unassignedComponents.count, 1)
        XCTAssertTrue(runtime.unassignedComponents[0].isStaleCandidate)
        XCTAssertEqual(runtime.staleCandidateCount, 2)
        XCTAssertNoThrow(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: runtime.sessions[0], kind: .staleCleanup),
            runtime: runtime
        ))
    }

    func testClaudeWrapperWithMCPArgumentsIsNotAnUnassignedBrowser() {
        let output = """
         400   1 1000 0.0 10:00 /Applications/Claude.app/Contents/MacOS/Claude
         410 400 1000 0.0 09:00 /Applications/Claude.app/Contents/Helpers/disclaimer --mcp-config firefox-devtools-mcp
         411 410 5000 0.2 09:00 /Users/test/Library/Application Support/Claude/claude-code/claude.app/Contents/MacOS/claude --mcp-config firefox-devtools-mcp
         412 411 2000 0.0 08:59 npm exec @mozilla/firefox-devtools-mcp@latest --headless
        """
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        )

        XCTAssertEqual(runtime.sessions.map(\.family), [.claudeCode])
        XCTAssertTrue(runtime.unassignedComponents.isEmpty)
        XCTAssertNoThrow(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: runtime.sessions[0], kind: .userRequested),
            runtime: runtime
        ))
    }

    func testUserRequestedTerminationIncludesClaudeSessionDescendants() {
        let output = """
         411   1 5000 0.2 02:32 /Users/test/Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude
         412 411 2000 0.0 02:31 /Users/test/Library/Application Support/Claude/claude-code/helper
         413 412 1000 0.0 02:30 node /workspace/custom-session-child.js
        """
        let table = ProcessTable.parse(output)
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: table,
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        )

        let session = try! XCTUnwrap(runtime.sessions.first)
        XCTAssertEqual(session.components.flatMap { $0.processes.map(\.pid) }, [411])
        XCTAssertEqual(
            AgentCleanupService.terminationPIDs(session: session, processTable: table),
            Set([411, 412, 413])
        )
        XCTAssertEqual(
            AgentCleanupService.protectedServicePortsOwned(
                by: Set([411, 412, 413]),
                listeningPorts: .init(processIDsByPort: [8_080: [412], 11_435: [999]])
            ),
            [8_080]
        )
    }

    func testUserRequestedTerminationAbortsWhenTaskCommandChanges() {
        func runtime(commandSuffix: String) -> AgentRuntimeSnapshot {
            let output = """
             411   1 5000 0.2 02:32 /Users/test/Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude \(commandSuffix)
            """
            return AgentRuntimeAnalyzer().analyze(
                processTable: .parse(output),
                listeningPorts: .init(processIDsByPort: [:]),
                workspaceRoot: URL(fileURLWithPath: "/workspace")
            )
        }

        let confirmedRuntime = runtime(commandSuffix: "--resume first")
        let changedRuntime = runtime(commandSuffix: "--resume replacement")
        let request = AgentSessionTerminationRequest(
            session: confirmedRuntime.sessions[0],
            kind: .userRequested
        )

        XCTAssertThrowsError(try AgentCleanupService.validatedSession(
            request: request,
            runtime: changedRuntime
        ))
    }

    func testClaudeSessionTitleUsesExactResumeIdentifier() {
        let sessionID = "37664d6d-1269-48f4-94ec-ad4e2a20d1d4"
        let output = """
         411   1 5000 0.2 02:32 /Users/test/Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude --resume \(sessionID) --resume-session-at 2ef1990e-8415-4bf6-ba14-42d3a109899f
        """
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            claudeSessionTitlesByPID: [411: "Analytics"]
        )

        XCTAssertEqual(ClaudeSessionMetadataService.resumeSessionID(in: output), sessionID)
        XCTAssertEqual(runtime.sessions.first?.title, "Claude Code · Analytics")
    }

    func testClaudeNewSessionTitleRequiresUniqueCreationTimeMatch() {
        let capturedAt = Date(timeIntervalSince1970: 10_000)
        let process = LocalProcess(
            pid: 500,
            parentPID: 1,
            residentBytes: 1,
            cpuPercent: 0,
            elapsed: "00:30",
            command: "/Users/test/Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude"
        )
        let matching = ClaudeSessionMetadata(
            id: UUID().uuidString,
            title: "Ideas Hub design and build",
            createdAt: capturedAt.addingTimeInterval(-25)
        )

        XCTAssertEqual(
            ClaudeSessionMetadataService.resolveTitles(
                processes: [process],
                metadata: [matching],
                capturedAt: capturedAt
            )[500],
            "Ideas Hub design and build"
        )

        let ambiguous = ClaudeSessionMetadata(
            id: UUID().uuidString,
            title: "Another task",
            createdAt: capturedAt.addingTimeInterval(-34)
        )
        XCTAssertNil(ClaudeSessionMetadataService.resolveTitles(
            processes: [process],
            metadata: [matching, ambiguous],
            capturedAt: capturedAt
        )[500])
    }

    func testMemoryPressureParsingSeparatesOccupiedMemoryFromReserveScore() {
        let output = """
        The system has 51539607552 (3145728 pages with a page size of 16384).
        Pages free: 76542
        Pages speculative: 58482
        Pages wired down: 307995
        Pages used by compressor: 533991
        System-wide memory free percentage: 72%
        """

        let memory = RigService.parseSystemMemory(output, totalBytes: 51_539_607_552)

        XCTAssertEqual(memory.physicalUnusedBytes, 2_212_233_216)
        XCTAssertEqual(memory.physicalOccupiedBytes, 49_327_374_336)
        XCTAssertEqual(memory.wiredBytes, 5_046_190_080)
        XCTAssertEqual(memory.compressedBytes, 8_748_908_544)
        XCTAssertEqual(memory.pressureReservePercentage, 72)
        XCTAssertEqual(memory.pressureStatus, "Normal")
    }

    func testLocalModelMetricsAndOwnershipStayExact() {
        let metrics = """
        # HELP llamacpp:requests_processing Requests
        llamacpp:requests_processing 2
        llamacpp:prompt_tokens_seconds 187.4
        llamacpp:predicted_tokens_seconds 14.8
        """
        XCTAssertEqual(LocalModelService.metric("llamacpp:requests_processing", in: metrics), 2)
        XCTAssertEqual(LocalModelService.metric("llamacpp:prompt_tokens_seconds", in: metrics), 187.4)
        XCTAssertEqual(LocalModelService.metric("llamacpp:predicted_tokens_seconds", in: metrics), 14.8)

        let modelPath = "/Users/test/Library/Application Support/Local Rig/LocalModels/Models/qwen.gguf"
        let owned = "/opt/homebrew/bin/llama-server -m \(modelPath) --port 11435"
        XCTAssertTrue(LocalModelService.isManagedCommand(owned, modelPath: modelPath, port: 11_435))
        XCTAssertFalse(LocalModelService.isManagedCommand(owned, modelPath: modelPath, port: 11_436))
        XCTAssertFalse(LocalModelService.isManagedCommand(
            "/opt/homebrew/bin/llama-server -m /Users/test/other.gguf --port 11435",
            modelPath: modelPath,
            port: 11_435
        ))
    }

    func testQwenRoadmapDoesNotPretendUnreleasedModelsAreInstallable() {
        XCTAssertNotNil(LocalModelChoice.qwen36_27B_Q4.downloadURL)
        XCTAssertEqual(LocalModelChoice.qwen36_27B_Q4.expectedDownloadBytes, 17_980_000_000)
        XCTAssertFalse(LocalModelService.isModelComplete(choice: .qwen36_27B_Q4, bytes: 1_000_000))
        XCTAssertTrue(LocalModelService.isModelComplete(choice: .qwen36_27B_Q4, bytes: 17_500_000_000))
        XCTAssertNil(LocalModelChoice.qwen38_27B.downloadURL)
        XCTAssertNil(LocalModelChoice.qwen38Max.downloadURL)
    }

    func testMuseGlimmerManifestUsesOfficialVerifiedArtifacts() throws {
        let dynamic = LocalModelChoice.museGlimmerDynamic
        let compact = LocalModelChoice.museGlimmer17GB

        XCTAssertEqual(dynamic.minimumSystemMemoryBytes, 32_000_000_000)
        XCTAssertEqual(compact.minimumSystemMemoryBytes, 24_000_000_000)
        XCTAssertEqual(dynamic.mainArtifact.fileName, "muse-glimmer-30B-kquant-dynamic.gguf")
        XCTAssertEqual(dynamic.mainArtifact.expectedBytes, 19_653_957_984)
        XCTAssertEqual(dynamic.mainArtifact.sha256, "513109c8319115f69eb09fb7b118c97c8167d15bc014fd7670d2e30489bf106c")
        XCTAssertEqual(compact.mainArtifact.fileName, "muse-glimmer-30B-kquant-17gb.gguf")
        XCTAssertEqual(compact.mainArtifact.expectedBytes, 16_756_681_056)

        let full = dynamic.requiredArtifacts(for: .full)
        XCTAssertEqual(full.map(\.role), [.main, .vision, .draft])
        XCTAssertEqual(full.map(\.fileName), [
            "muse-glimmer-30B-kquant-dynamic.gguf",
            "mmproj-kquant.gguf",
            "dflash-kquant.gguf",
        ])
        XCTAssertTrue(full.allSatisfy { $0.downloadURL.host == "huggingface.co" })
        XCTAssertTrue(full.allSatisfy { !$0.sha256.isEmpty })
        XCTAssertEqual(dynamic.requiredArtifacts(for: .textOnly).map(\.role), [.main])
    }

    func testMuseGlimmerLaunchDisablesBrokenOfficialDFlashPath() {
        XCTAssertEqual(LocalModelProfile.economy.contextSize, 16_384)
        XCTAssertEqual(LocalModelProfile.standard.contextSize, 32_768)
        XCTAssertEqual(LocalModelProfile.deep.contextSize, 65_536)
        XCTAssertEqual(
            LocalModelChoice.museGlimmerDynamic.supportedFeatureProfiles,
            [.textOnly, .vision]
        )

        let directory = URL(fileURLWithPath: "/models", isDirectory: true)
        let arguments = LocalModelService.launchArguments(
            choice: .museGlimmerDynamic,
            profile: .standard,
            features: .accelerated,
            modelsDirectory: directory,
            port: 11_435
        )

        XCTAssertTrue(arguments.containsSubsequence(["-m", "/models/muse-glimmer-30B-kquant-dynamic.gguf"]))
        XCTAssertFalse(arguments.contains("--mmproj"))
        XCTAssertFalse(arguments.contains("--model-draft"))
        XCTAssertFalse(arguments.contains("--spec-type"))
        XCTAssertTrue(arguments.containsSubsequence(["--ctx-size", "32768"]))
        XCTAssertTrue(arguments.containsSubsequence(["--sleep-idle-seconds", "180"]))
        XCTAssertTrue(arguments.containsSubsequence(["--alias", "muse-glimmer"]))
        XCTAssertTrue(arguments.containsSubsequence(["--temp", "1.0"]))
        XCTAssertTrue(arguments.containsSubsequence(["--top-p", "0.95"]))
        XCTAssertTrue(arguments.containsSubsequence(["--top-k", "64"]))
        XCTAssertEqual(LocalModelService.sleepSafeMonitoringPaths, ["/health", "/props"])
        XCTAssertFalse(LocalModelService.sleepSafeMonitoringPaths.contains("/metrics"))

        let vision = LocalModelService.launchArguments(
            choice: .museGlimmerDynamic,
            profile: .standard,
            features: .vision,
            modelsDirectory: directory,
            port: 11_435
        )
        XCTAssertTrue(vision.containsSubsequence(["--mmproj", "/models/mmproj-kquant.gguf"]))
        XCTAssertFalse(vision.contains("--model-draft"))

        let qwen = LocalModelService.launchArguments(
            choice: .qwen36_27B_Q4,
            profile: .economy,
            features: .full,
            modelsDirectory: directory,
            port: 11_435
        )
        XCTAssertFalse(qwen.contains("--mmproj"))
        XCTAssertFalse(qwen.contains("--model-draft"))
        XCTAssertFalse(qwen.contains("--spec-type"))
    }

    func testMuseGlimmerCompletenessAndStartPolicyAreConservative() {
        let artifact = LocalModelChoice.museGlimmerDynamic.mainArtifact
        XCTAssertFalse(LocalModelService.isArtifactComplete(artifact, bytes: artifact.expectedBytes - 1))
        XCTAssertTrue(LocalModelService.isArtifactComplete(artifact, bytes: artifact.expectedBytes))

        let constrained = SystemMemorySnapshot(
            totalBytes: 24_000_000_000,
            physicalOccupiedBytes: 12_000_000_000,
            physicalUnusedBytes: 12_000_000_000,
            wiredBytes: 2_000_000_000,
            compressedBytes: 0,
            pressureReservePercentage: 80
        )
        XCTAssertNotNil(LocalModelService.startBlockReason(choice: .museGlimmerDynamic, memory: constrained))
        XCTAssertNil(LocalModelService.startBlockReason(choice: .museGlimmer17GB, memory: constrained))

        let pressured = SystemMemorySnapshot(
            totalBytes: 51_539_607_552,
            physicalOccupiedBytes: 49_000_000_000,
            physicalUnusedBytes: 2_539_607_552,
            wiredBytes: 6_000_000_000,
            compressedBytes: 12_000_000_000,
            pressureReservePercentage: 19
        )
        XCTAssertNotNil(LocalModelService.startBlockReason(choice: .museGlimmer17GB, memory: pressured))
    }

    func testMuseGlimmerArtifactSetRequiresEverySelectedComponent() throws {
        let artifacts = LocalModelChoice.museGlimmerDynamic.requiredArtifacts(for: .full)
        var sizes = [artifacts[0].fileName: artifacts[0].expectedBytes]

        XCTAssertFalse(LocalModelService.artifactsAreComplete(artifacts, sizesByFileName: sizes))
        sizes[artifacts[1].fileName] = artifacts[1].expectedBytes
        sizes[artifacts[2].fileName] = artifacts[2].expectedBytes
        XCTAssertTrue(LocalModelService.artifactsAreComplete(artifacts, sizesByFileName: sizes))

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-rig-sha-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertEqual(
            try LocalModelService.sha256(of: temporary),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testCodexCohortIdentityDoesNotChangeWithElapsedTime() {
        func sessionID(elapsed: String) -> String? {
            let output = """
             100   1 5000 0.0 01:00 /Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled
             110 100 1000 0.0 \(elapsed) /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
             111 100 2000 0.0 \(elapsed) npm exec @mozilla/firefox-devtools-mcp@latest --headless
            """
            return AgentRuntimeAnalyzer().analyze(
                processTable: .parse(output),
                listeningPorts: .init(processIDsByPort: [:]),
                workspaceRoot: URL(fileURLWithPath: "/workspace")
            ).sessions.first?.id
        }

        XCTAssertEqual(sessionID(elapsed: "00:30"), sessionID(elapsed: "00:38"))
        XCTAssertEqual(sessionID(elapsed: "00:30"), "codex-100-110")
    }

    func testActiveCodexTurnMetadataNamesCohortAndSuppressesStaleCleanup() {
        let output = """
         100   1 5000 0.0 30:00 /Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled
         110 100 1000 0.0 26:00 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
         111 100 2000 0.0 26:00 node /workspace/local-rig/mcp/server.mjs
        """
        let metadata = CodexCohortMetadata(
            threadID: "019fd2e4-47ea-71d0-93b3-d2a2980982b2",
            title: "Rig App keychain shite signing prompt",
            isTurnActive: true
        )
        let runtime = AgentRuntimeAnalyzer().analyze(
            processTable: .parse(output),
            listeningPorts: .init(processIDsByPort: [:]),
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            codexSessionMetadataByPID: [110: metadata]
        )

        XCTAssertEqual(runtime.sessions.first?.title, "Codex · Rig App keychain shite signing prompt")
        XCTAssertEqual(runtime.sessions.first?.activeSessionCount, 1)
        XCTAssertEqual(runtime.sessions.first?.inactiveSessionCount, 0)
        XCTAssertFalse(runtime.sessions.first?.isStaleCandidate == true)
        let activeSession = runtime.sessions[0]
        XCTAssertNoThrow(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: activeSession, kind: .userRequested),
            runtime: runtime
        ))
        XCTAssertThrowsError(try AgentCleanupService.validatedSession(
            request: AgentSessionTerminationRequest(session: activeSession, kind: .staleCleanup),
            runtime: runtime
        ))
    }

    func testCodexMetadataRequiresUniqueNearbyTurnStart() {
        let cohortStart = Date(timeIntervalSince1970: 10_000)
        let rigThreadID = "019fd2e4-47ea-71d0-93b3-d2a2980982b2"
        let rigActivity = CodexRolloutActivity(
            threadID: rigThreadID,
            events: [CodexTurnEvent(date: cohortStart.addingTimeInterval(15), kind: .started)]
        )

        let resolved = CodexSessionMetadataService.resolveMetadata(
            cohortStartsByPID: [110: cohortStart],
            activities: [rigActivity],
            threadDescriptions: [rigThreadID: "Rig App"]
        )
        XCTAssertEqual(resolved[110]?.threadID, rigThreadID)
        XCTAssertEqual(resolved[110]?.title, "Rig App")
        XCTAssertTrue(resolved[110]?.isTurnActive == true)

        let ambiguousActivity = CodexRolloutActivity(
            threadID: "019fd2e4-47ea-71d0-93b3-d2a2980982b3",
            events: [CodexTurnEvent(date: cohortStart.addingTimeInterval(18), kind: .started)]
        )
        XCTAssertNil(CodexSessionMetadataService.resolveMetadata(
            cohortStartsByPID: [110: cohortStart],
            activities: [rigActivity, ambiguousActivity],
            threadDescriptions: [:]
        )[110])
    }

    func testRuntimeExpansionStatePersistsAndReconciles() async {
        await MainActor.run {
            let suiteName = "RuntimeExpansionStoreTests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Could not create isolated UserDefaults suite")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let first = RuntimeExpansionStore(defaults: defaults)
            first.setSession("codex-100-110", expanded: false)
            first.setComponent(111, expanded: true)

            let restored = RuntimeExpansionStore(defaults: defaults)
            XCTAssertFalse(restored.isSessionExpanded("codex-100-110"))
            XCTAssertTrue(restored.isComponentExpanded(111))

            restored.reconcile(sessionIDs: ["codex-200-210"], componentPIDs: [211])
            XCTAssertTrue(restored.isSessionExpanded("codex-100-110"))
            XCTAssertFalse(restored.isComponentExpanded(111))
        }
    }

    func testListeningPortsTreatsPortAsTruth() {
        let output = """
        p101
        n127.0.0.1:3000
        p202
        n*:8080
        n127.0.0.1:4000
        """

        let ports = ListeningPorts.parse(output)

        XCTAssertEqual(ports.processIDs(on: 3000), [101])
        XCTAssertEqual(ports.processIDs(on: 8080), [202])
        XCTAssertEqual(ports.processIDs(on: 4000), [202])
        XCTAssertTrue(ports.processIDs(on: 5001).isEmpty)
    }

    func testLogSanitizerRedactsCommonCredentialShapes() {
        let raw = """
        Authorization: Bearer abc.def.ghi
        API_KEY=AIzaabcdefghijklmnopqrstuvwxyz12345
        refresh_token: super-secret-value
        account: qa.person@example.com
        safe message remains
        """

        let sanitized = LogSanitizer.sanitize(raw)

        XCTAssertFalse(sanitized.contains("abc.def.ghi"))
        XCTAssertFalse(sanitized.contains("AIzaabcdefghijklmnopqrstuvwxyz12345"))
        XCTAssertFalse(sanitized.contains("super-secret-value"))
        XCTAssertFalse(sanitized.contains("qa.person@example.com"))
        XCTAssertTrue(sanitized.contains("safe message remains"))
    }

    func testLogSanitizerRedactsCredentialCommandArguments() {
        let sanitized = LogSanitizer.sanitize(
            "npx vercel-mcp --api-key very-secret-value --access-token=another-secret"
        )

        XCTAssertFalse(sanitized.contains("very-secret-value"))
        XCTAssertFalse(sanitized.contains("another-secret"))
        XCTAssertTrue(sanitized.contains("--api-key <redacted>"))
        XCTAssertTrue(sanitized.contains("--access-token=<redacted>"))
    }

    func testClaimNameValidationRejectsShellSyntax() {
        XCTAssertTrue(RigCommandService.isValidClaimName("archie-rig-app"))
        XCTAssertFalse(RigCommandService.isValidClaimName("archie; rm -rf"))
        XCTAssertFalse(RigCommandService.isValidClaimName(""))
    }

    func testSharedAndIsolatedStartsSelectModeExplicitly() {
        XCTAssertEqual(RigCommand.startShared.arguments, ["up", "--shared"])
        XCTAssertEqual(RigCommand.startIsolated.arguments, ["up", "--iso"])
    }

    func testSharedRigUsesRigOneEmulatorStateAndIsolatedRigUsesItsOwn() {
        let root = URL(fileURLWithPath: "/tmp/rheos-root")
        let rigFourState = root.appendingPathComponent(".rig2/4")

        XCTAssertEqual(
            RigService.emulatorStateDirectory(index: 4, mode: .shared, state: rigFourState, root: root).path,
            root.appendingPathComponent(".rig2/1").path
        )
        XCTAssertEqual(
            RigService.emulatorStateDirectory(index: 4, mode: .isolated, state: rigFourState, root: root).path,
            rigFourState.path
        )
    }

    func testBoundDirectoryUsesPersistedWorktreePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-rig-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = root.appendingPathComponent("dashboard-root")
        let fallback = root.appendingPathComponent("wt-rig2")
        let bound = root.appendingPathComponent("wt-onboarding")
        try bound.path.write(to: stateFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(RigService.boundDirectory(stateFile, fallback: fallback).path, bound.path)
        XCTAssertEqual(RigService.boundDirectory(root.appendingPathComponent("missing"), fallback: fallback).path, fallback.path)
    }

    func testANSIStrippingKeepsReadableStatus() {
        XCTAssertEqual(ANSI.strip(from: "\u{001B}[32mup\u{001B}[0m :3000"), "up :3000")
    }

    func testAgentHandoffWritesStableRedactedArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-rig-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = RigServiceStatus(
            kind: .dev,
            port: 3000,
            isListening: true,
            processes: [],
            isShared: false
        )
        let rig = RigSnapshot(
            id: 1,
            holder: "test",
            mode: .shared,
            profile: .fast,
            controller: .legacy,
            repository: RepositoryIdentity(
                path: root.path,
                exists: true,
                branch: "main",
                commit: "abc123",
                summary: "test"
            ),
            backendRepository: RepositoryIdentity(
                path: root.appendingPathComponent("backend").path,
                exists: true,
                branch: "backend-fix",
                commit: "def456",
                summary: "backend test"
            ),
            services: [service],
            devResidentBytes: 1_024,
            emulatorResidentBytes: 0,
            devLogPath: root.appendingPathComponent("dev.log").path,
            emulatorLogPath: root.appendingPathComponent("emu.log").path,
            devLogTail: "user qa.person@example.com token=secret-value",
            emulatorLogTail: "safe emulator line"
        )
        let privateProcess = LocalProcess(
            pid: 987,
            parentPID: 1,
            residentBytes: 2_048,
            cpuPercent: 0,
            elapsed: "12:00",
            command: "node server.js token=must-not-enter-agent-artifact"
        )
        let privateComponent = RuntimeComponent(
            rootPID: privateProcess.pid,
            name: "Local MCP",
            kind: .mcp,
            processes: [privateProcess],
            repositoryPath: root.path,
            listeningPorts: [],
            staleReasons: ["review"]
        )
        let snapshot = DashboardSnapshot(
            capturedAt: Date(),
            workspaceRoot: root.path,
            rig2IsVerified: false,
            systemMemory: SystemMemorySnapshot(
                totalBytes: 16_000,
                physicalOccupiedBytes: 12_000,
                physicalUnusedBytes: 4_000,
                wiredBytes: 2_000,
                compressedBytes: 3_000,
                pressureReservePercentage: 50
            ),
            rigs: [rig],
            agentRuntime: AgentRuntimeSnapshot(hosts: [], sessions: [], unassignedComponents: [privateComponent], devServers: []),
            localModel: LocalModelSnapshot(
                selectedModel: .qwen36_27B_Q4,
                profile: .standard,
                featureProfile: .textOnly,
                status: .stopped,
                runtimeExecutablePath: "/opt/homebrew/bin/llama-server",
                endpoint: "http://127.0.0.1:11435/v1",
                port: 11_435,
                processPID: nil,
                residentBytes: 0,
                modelFilePath: nil,
                modelFileBytes: 0,
                requiredArtifactCount: 1,
                downloadedArtifactCount: 0,
                logPath: "/tmp/llama-server.log",
                redactedLogTail: "safe local model line",
                healthDetail: nil,
                requestsProcessing: 0,
                promptTokensPerSecond: nil,
                predictedTokensPerSecond: nil
            )
        )

        let result = try AgentArtifactWriter().createHandoff(
            snapshot: snapshot,
            rig: rig,
            commandOutput: "API_KEY=top-secret"
        )
        let content = try String(contentsOf: result.url, encoding: .utf8)
        let latest = root.appendingPathComponent(".rig-dashboard/handoffs/latest.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
        XCTAssertFalse(content.contains("qa.person@example.com"))
        XCTAssertFalse(content.contains("secret-value"))
        XCTAssertFalse(content.contains("top-secret"))
        XCTAssertTrue(content.contains("Memory pressure: Normal"))
        XCTAssertTrue(result.prompt.contains(result.url.path))

        let currentURL = try AgentArtifactWriter().writeCurrent(snapshot: snapshot)
        let current = try String(contentsOf: currentURL, encoding: .utf8)
        XCTAssertTrue(content.contains("## Backend worktree"))
        XCTAssertTrue(content.contains("backend-fix"))
        XCTAssertTrue(current.contains("\"schemaVersion\" : 8"))
        XCTAssertTrue(current.contains("\"agentRuntime\""))
        XCTAssertTrue(current.contains("\"devServers\""))
        XCTAssertTrue(current.contains("\"mcpUsageByType\""))
        XCTAssertTrue(current.contains("\"localModel\""))
        XCTAssertTrue(current.contains("\"featureProfile\" : \"textOnly\""))
        XCTAssertTrue(current.contains("\"requiredArtifactCount\" : 1"))
        XCTAssertFalse(current.contains("must-not-enter-agent-artifact"))
        XCTAssertTrue(current.contains("\"physicalOccupiedBytes\" : 12000"))
        XCTAssertFalse(current.contains("freePercentage"))
    }

    func testArtifactWriteCoordinatorKeepsNewestConcurrentSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-rig-artifact-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = makeMinimalSnapshot(
            root: root,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = makeMinimalSnapshot(
            root: root,
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        let coordinator = AgentArtifactWriteCoordinator()

        async let olderWrite = coordinator.writeCurrent(snapshot: older)
        async let newerWrite = coordinator.writeCurrent(snapshot: newer)
        _ = try await (olderWrite, newerWrite)

        let currentURL = root.appendingPathComponent(".rig-dashboard/current.json")
        let data = try Data(contentsOf: currentURL)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["capturedAt"] as? String, "1970-01-01T00:33:20Z")
    }

    private func makeMinimalSnapshot(root: URL, capturedAt: Date) -> DashboardSnapshot {
        DashboardSnapshot(
            capturedAt: capturedAt,
            workspaceRoot: root.path,
            rig2IsVerified: false,
            systemMemory: SystemMemorySnapshot(
                totalBytes: 16_000,
                physicalOccupiedBytes: 12_000,
                physicalUnusedBytes: 4_000,
                wiredBytes: 2_000,
                compressedBytes: 3_000,
                pressureReservePercentage: 50
            ),
            rigs: [],
            agentRuntime: AgentRuntimeSnapshot(
                hosts: [],
                sessions: [],
                unassignedComponents: [],
                devServers: []
            ),
            localModel: LocalModelSnapshot(
                selectedModel: .qwen36_27B_Q4,
                profile: .standard,
                featureProfile: .textOnly,
                status: .stopped,
                runtimeExecutablePath: "/opt/homebrew/bin/llama-server",
                endpoint: "http://127.0.0.1:11435/v1",
                port: 11_435,
                processPID: nil,
                residentBytes: 0,
                modelFilePath: nil,
                modelFileBytes: 0,
                requiredArtifactCount: 1,
                downloadedArtifactCount: 0,
                logPath: "/tmp/llama-server.log",
                redactedLogTail: "",
                healthDetail: nil,
                requestsProcessing: 0,
                promptTokensPerSecond: nil,
                predictedTokensPerSecond: nil
            )
        )
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ candidate: [Element]) -> Bool {
        guard !candidate.isEmpty, candidate.count <= count else { return false }
        return indices.contains { start in
            let end = start + candidate.count
            guard end <= count else { return false }
            return Array(self[start..<end]) == candidate
        }
    }
}
