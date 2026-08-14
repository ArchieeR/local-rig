import AppKit
import Foundation
import OSLog

enum PreferenceKeys {
    static let workspaceRoot = "workspaceRoot"
    static let rig2ControlsEnabled = "rig2ControlsEnabled"
    static let claimName = "claimName"
    static let leanMode = "leanMode"
    static let localModelChoice = "localModelChoice"
    static let localModelProfile = "localModelProfile"
    static let localModelFeatureProfile = "localModelFeatureProfile"
    static let configuredRigIDs = "configuredRigIDs"
}

@MainActor
final class RigStore: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published var sidebarSelection: SidebarSelection = .rigs
    @Published private(set) var isRefreshing = false
    @Published private(set) var busyRigIDs: Set<Int> = []
    @Published private(set) var cleaningSessionIDs: Set<String> = []
    @Published private(set) var terminatingMCPTypeIDs: Set<String> = []
    @Published private(set) var terminatingDevServerIDs: Set<String> = []
    @Published private(set) var configuredRigIDs: Set<Int> = [1]
    @Published var leanMode: Bool {
        didSet {
            UserDefaults.standard.set(leanMode, forKey: PreferenceKeys.leanMode)
            if leanMode && sidebarSelection == .localModels {
                sidebarSelection = .runtime
            }
        }
    }
    @Published private(set) var isLocalModelBusy = false
    @Published private(set) var commandLog: [CommandLogEntry] = []
    @Published var errorMessage: String?
    @Published var handoffResult: AgentHandoffResult?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.localrig.LocalRig", category: "Dashboard")
    private let resolver = WorkspaceResolver()
    private let rigService = RigService()
    private let commandService = RigCommandService()
    private let cleanupService = AgentCleanupService()
    private let mcpTerminationService = MCPGroupTerminationService()
    private let devServerTerminationService = DevServerTerminationService()
    private let artifactWriter = AgentArtifactWriter()
    private let artifactWriteCoordinator = AgentArtifactWriteCoordinator()
    private let localModelService = LocalModelService.shared
    private var monitorTask: Task<Void, Never>?
    private var settingsRefreshTask: Task<Void, Never>?
    private var lastRuntimeSummary: String?

    init() {
        if let savedLeanMode = UserDefaults.standard.object(forKey: PreferenceKeys.leanMode) as? Bool {
            leanMode = savedLeanMode
        } else {
            leanMode = ProcessInfo.processInfo.physicalMemory <= 24 * 1_024 * 1_024 * 1_024
            UserDefaults.standard.set(leanMode, forKey: PreferenceKeys.leanMode)
        }
        let saved = UserDefaults.standard.string(forKey: PreferenceKeys.configuredRigIDs) ?? "1"
        let parsed = Set(saved.split(separator: ",").compactMap { Int($0) }.filter { (1...5).contains($0) })
        configuredRigIDs = parsed.isEmpty ? [1] : parsed.union([1])
    }

    var selectedRigID: Int {
        get {
            if case let .rig(id) = sidebarSelection { return id }
            return 0
        }
        set {
            switch newValue {
            case -1: sidebarSelection = .localModels
            case 1...5: sidebarSelection = .rig(newValue)
            default: sidebarSelection = .runtime
            }
        }
    }

    var selectedRig: RigSnapshot? {
        snapshot?.rigs.first(where: { $0.id == selectedRigID })
    }

    var agentRuntime: AgentRuntimeSnapshot? { snapshot?.agentRuntime }
    var isMachineSelected: Bool {
        switch sidebarSelection {
        case .runtime: true
        case .localModels, .rigs, .devServers, .mcps, .rig: false
        }
    }
    var isLocalModelSelected: Bool { sidebarSelection == .localModels }

    var visibleRigs: [RigSnapshot] {
        (snapshot?.rigs ?? []).filter {
            configuredRigIDs.contains($0.id)
                || $0.devIsRunning
                || $0.emulatorIsRunning
                || $0.holder != nil
        }
    }

    var workspaceRoot: URL? {
        resolver.resolve(configuredPath: UserDefaults.standard.string(forKey: PreferenceKeys.workspaceRoot))
    }

    var rig2ControlsEnabled: Bool {
        rig2IsVerified || UserDefaults.standard.bool(forKey: PreferenceKeys.rig2ControlsEnabled)
    }

    var rig2IsVerified: Bool {
        guard let root = workspaceRoot else { return false }
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".rig2/VERIFIED").path
        )
    }

    var claimName: String {
        UserDefaults.standard.string(forKey: PreferenceKeys.claimName)?.nilIfBlank
            ?? RigCommandService.normalizedSessionName()
    }

    var isSelectedRigBusy: Bool { busyRigIDs.contains(selectedRigID) }

    var runningRigCount: Int {
        snapshot?.rigs.filter(\.devIsRunning).count ?? 0
    }

    var menuBarSymbol: String {
        if snapshot == nil { return "questionmark.circle" }
        if let stale = snapshot?.agentRuntime.staleCandidateCount, stale > 0 {
            return "exclamationmark.triangle.fill"
        }
        return runningRigCount > 0 ? "bolt.circle.fill" : "bolt.circle"
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: UInt64 = self?.leanMode == true ? 12_000_000_000 : 8_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func chooseWorkspace() {
        guard let url = PanelService.chooseWorkspace() else { return }
        UserDefaults.standard.set(url.path, forKey: PreferenceKeys.workspaceRoot)
        Task { await refresh() }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
    }

    deinit {
        monitorTask?.cancel()
        settingsRefreshTask?.cancel()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let root = workspaceRoot else {
            errorMessage = "Could not find the development workspace. Choose it in Settings."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let newSnapshot = try await rigService.snapshot(
                workspaceRoot: root,
                rig2ControlsEnabled: rig2ControlsEnabled
            )
            snapshot = newSnapshot
            errorMessage = nil
            if case let .rig(selectedID) = sidebarSelection,
               !newSnapshot.rigs.contains(where: { $0.id == selectedID }) {
                sidebarSelection = .runtime
            }
            let coordinator = artifactWriteCoordinator
            Task(priority: .utility) {
                do {
                    _ = try await coordinator.writeCurrent(snapshot: newSnapshot)
                } catch {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.localrig.LocalRig", category: "Dashboard")
                        .error("Failed to write current.json: \(error.localizedDescription, privacy: .public)")
                }
            }
            let runtimeSummary = "sessions=\(newSnapshot.agentRuntime.estimatedSessionCount) active=\(newSnapshot.agentRuntime.activeSessionCount) mcps=\(newSnapshot.agentRuntime.mcpCount) stale=\(newSnapshot.agentRuntime.staleCandidateCount)"
            if runtimeSummary != lastRuntimeSummary {
                logger.info("Agent runtime changed: \(runtimeSummary, privacy: .public)")
                lastRuntimeSummary = runtimeSummary
            }
            logger.debug("Refreshed \(newSnapshot.rigs.count, privacy: .public) rigs, \(newSnapshot.agentRuntime.estimatedSessionCount, privacy: .public) sessions, \(newSnapshot.agentRuntime.mcpCount, privacy: .public) MCPs, \(newSnapshot.agentRuntime.staleCandidateCount, privacy: .public) stale candidates")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func run(_ command: RigCommand, on rigID: Int? = nil) async {
        let targetID = rigID ?? selectedRigID
        guard (1...5).contains(targetID), !busyRigIDs.contains(targetID), let root = workspaceRoot else { return }
        busyRigIDs.insert(targetID)
        defer { busyRigIDs.remove(targetID) }

        do {
            let result = try await commandService.run(
                command,
                rigID: targetID,
                workspaceRoot: root,
                rig2ControlsEnabled: rig2ControlsEnabled,
                sessionName: claimName
            )
            commandLog.insert(CommandLogEntry(
                date: Date(),
                rigID: targetID,
                title: command.title,
                result: result
            ), at: 0)
            commandLog = Array(commandLog.prefix(40))
            if !result.succeeded {
                errorMessage = result.combinedOutput.nilIfBlank
                    ?? "\(command.title) failed with exit code \(result.exitCode)."
                logger.error("Command \(command.title, privacy: .public) failed for rig \(targetID, privacy: .public)")
            } else {
                errorMessage = nil
                logger.info("Command \(command.title, privacy: .public) completed for rig \(targetID, privacy: .public)")
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Command failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }

    func terminateAgentSession(
        _ session: AgentSessionGroup,
        kind: AgentSessionTerminationKind
    ) async {
        guard !cleaningSessionIDs.contains(session.id), let root = workspaceRoot else { return }
        cleaningSessionIDs.insert(session.id)
        defer { cleaningSessionIDs.remove(session.id) }

        var cleanupMessage: String?
        do {
            let result = try await cleanupService.terminateSession(
                request: AgentSessionTerminationRequest(session: session, kind: kind),
                workspaceRoot: root
            )
            if result.survivorPIDs.isEmpty {
                logger.info("Gracefully ended agent session \(session.id, privacy: .public), signalling \(result.signalledProcessCount, privacy: .public) processes")
            } else {
                cleanupMessage = "Graceful stop was sent, but \(result.survivorPIDs.count) processes remain. They were not force-killed. Refresh and review them before trying anything else."
                logger.warning("Session stop left \(result.survivorPIDs.count, privacy: .public) survivors for \(session.id, privacy: .public)")
            }
        } catch {
            cleanupMessage = "Session stop aborted safely: \(error.localizedDescription)"
            logger.error("Session stop validation failed for \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
        // A successful refresh clears stale errors, so restore cleanup-specific
        // feedback afterward when validation failed or processes survived.
        if let cleanupMessage {
            errorMessage = cleanupMessage
        }
    }

    func terminateMCPGroup(_ usage: MCPUsageSnapshot) async {
        guard !terminatingMCPTypeIDs.contains(usage.id),
              let runtime = snapshot?.agentRuntime,
              let root = workspaceRoot else { return }
        terminatingMCPTypeIDs.insert(usage.id)
        defer { terminatingMCPTypeIDs.remove(usage.id) }

        var feedback: String?
        do {
            let result = try await mcpTerminationService.terminate(
                request: MCPGroupTerminationRequest(usage: usage, runtime: runtime),
                workspaceRoot: root
            )
            if !result.survivorPIDs.isEmpty {
                feedback = "Graceful MCP stop was sent, but \(result.survivorPIDs.count) processes remain. They were not force-killed."
            }
        } catch {
            feedback = "MCP group stop aborted safely: \(error.localizedDescription)"
        }
        await refresh()
        if let feedback { errorMessage = feedback }
    }

    func terminateDevServer(_ server: DevServerSnapshot) async {
        guard !terminatingDevServerIDs.contains(server.id),
              let root = workspaceRoot else { return }
        terminatingDevServerIDs.insert(server.id)
        defer { terminatingDevServerIDs.remove(server.id) }

        if let rig = controlledRig(for: server), rig.holder == claimName {
            await run(.stopDev, on: rig.id)
            return
        }

        var feedback: String?
        do {
            let result = try await devServerTerminationService.terminate(
                request: DevServerTerminationRequest(server: server),
                workspaceRoot: root
            )
            if !result.survivorPIDs.isEmpty {
                feedback = "Graceful dev-server stop was sent, but \(result.survivorPIDs.count) processes remain. They were not force-killed."
            }
        } catch {
            feedback = "Dev-server stop aborted safely: \(error.localizedDescription)"
        }
        await refresh()
        if let feedback { errorMessage = feedback }
    }

    func controlledRig(for server: DevServerSnapshot) -> RigSnapshot? {
        snapshot?.rigs.first { rig in
            guard rig.devIsRunning,
                  rig.devPort == server.port,
                  let repositoryPath = server.repositoryPath else { return false }
            return URL(fileURLWithPath: rig.repository.path).standardizedFileURL.path
                == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        }
    }

    func createNewRig() async {
        let visibleIDs = Set(visibleRigs.map(\.id)).union(configuredRigIDs)
        guard let id = (2...5).first(where: { !visibleIDs.contains($0) }) else {
            errorMessage = "All five controller slots are already created or active."
            return
        }
        configuredRigIDs.insert(id)
        persistConfiguredRigs()
        sidebarSelection = .rigs
        await run(.claim(claimName), on: id)
    }

    private func persistConfiguredRigs() {
        let value = configuredRigIDs.sorted().map(String.init).joined(separator: ",")
        UserDefaults.standard.set(value, forKey: PreferenceKeys.configuredRigIDs)
    }

    func installLocalModelRuntime() async {
        guard !isLocalModelBusy else { return }
        isLocalModelBusy = true
        defer { isLocalModelBusy = false }
        do {
            _ = try await localModelService.installRuntime()
            errorMessage = nil
        } catch {
            errorMessage = "Local model setup failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    func downloadLocalModel() async {
        guard !isLocalModelBusy else { return }
        isLocalModelBusy = true
        defer { isLocalModelBusy = false }
        do {
            _ = try await localModelService.downloadSelectedModel()
            errorMessage = nil
        } catch {
            errorMessage = "Model download failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    func startLocalModel() async {
        guard !isLocalModelBusy, let memory = snapshot?.systemMemory else { return }
        isLocalModelBusy = true
        defer { isLocalModelBusy = false }
        do {
            try await localModelService.start(memory: memory)
            errorMessage = nil
        } catch {
            errorMessage = "Local model did not start: \(error.localizedDescription)"
        }
        try? await Task.sleep(nanoseconds: 750_000_000)
        await refresh()
    }

    func stopLocalModel() async {
        guard !isLocalModelBusy else { return }
        isLocalModelBusy = true
        defer { isLocalModelBusy = false }
        do {
            try await localModelService.stop()
            errorMessage = nil
        } catch {
            errorMessage = "Local model was not stopped: \(error.localizedDescription)"
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refresh()
    }

    func localModelSettingsDidChange() {
        Task { await refresh() }
    }

    func latestCommandOutput(for rigID: Int) -> String? {
        guard let entry = commandLog.first(where: { $0.rigID == rigID }) else { return nil }
        return "$ \(entry.result.command)\n\(entry.result.combinedOutput)"
    }

    func createAgentHandoff() {
        guard let snapshot, let rig = selectedRig else { return }
        do {
            let result = try artifactWriter.createHandoff(
                snapshot: snapshot,
                rig: rig,
                commandOutput: latestCommandOutput(for: rig.id)
            )
            PasteboardService.copy(result.prompt)
            handoffResult = result
        } catch {
            errorMessage = "Could not create agent handoff: \(error.localizedDescription)"
        }
    }

    func createProcessReviewHandoff() {
        guard let snapshot, let root = workspaceRoot else { return }
        let url = root.appendingPathComponent(".rig-dashboard/current.json")
        let prompt = "Review the agent runtime snapshot at \(url.path). Explain which Codex/Claude sessions, MCP cohorts, browser automation processes, and workspace Node processes are active, and which are conservative stale candidates. Re-check live process state before recommending cleanup. Do not terminate anything without my explicit approval."
        PasteboardService.copy(prompt)
        handoffResult = AgentHandoffResult(
            url: url,
            prompt: prompt,
            title: "Process review ready",
            summary: "The redacted runtime inventory is available to agents, and a review prompt is on your clipboard. Raw command lines are deliberately excluded from the artifact."
        )
        logger.info("Created process review handoff with \(snapshot.agentRuntime.staleCandidateCount, privacy: .public) stale candidates")
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func settingsDidChange() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.settingsRefreshTask = nil
            await self.refresh()
        }
    }
}
