import Darwin
import CryptoKit
import Foundation

enum LocalModelServiceError: LocalizedError {
    case runtimeMissing
    case weightsUnavailable
    case modelNotDownloaded
    case memoryPressureCritical
    case alreadyRunning
    case notOwned
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "llama.cpp is not installed. Install the runtime first."
        case .weightsUnavailable:
            "That model does not have a verified local weight package yet."
        case .modelNotDownloaded:
            "Download the selected model before starting it."
        case .memoryPressureCritical:
            "Memory pressure is critical. Local Rig will not load another model."
        case .alreadyRunning:
            "A Local Rig model process is already running."
        case .notOwned:
            "The saved process no longer matches Local Rig's model command, so it was not stopped."
        case let .commandFailed(message):
            message
        }
    }
}

actor LocalModelService {
    static let shared = LocalModelService()
    static let sleepSafeMonitoringPaths = ["/health", "/props"]

    private let inspection = ProcessInspectionService()
    private let runner = ProcessRunner()
    private let logTail = LogTailService()
    private let port = 11_435
    private var managedProcess: Process?
    private var isDownloading = false

    private var applicationSupport: URL {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = library.appendingPathComponent("Local Rig/LocalModels", isDirectory: true)
        let legacy = library.appendingPathComponent("RheosRig/LocalModels", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: current.path),
              FileManager.default.fileExists(atPath: legacy.path) else {
            return current
        }
        do {
            try FileManager.default.createDirectory(
                at: current.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: legacy, to: current)
            return current
        } catch {
            // Keep existing downloads usable if the one-time rename cannot move them.
            return legacy
        }
    }
    private var modelsDirectory: URL { applicationSupport.appendingPathComponent("Models", isDirectory: true) }
    private var logsDirectory: URL { applicationSupport.appendingPathComponent("Logs", isDirectory: true) }
    private var logURL: URL { logsDirectory.appendingPathComponent("llama-server.log") }
    private var pidURL: URL { applicationSupport.appendingPathComponent("llama-server.pid") }

    func snapshot(processTable: ProcessTable, listeningPorts: ListeningPorts) async -> LocalModelSnapshot {
        let choice = selectedChoice
        let profile = selectedProfile
        let features = selectedFeatureProfile
        let runtime = runtimeExecutable
        let artifacts = choice.requiredArtifacts(for: features)
        let sizesByFileName = Dictionary(uniqueKeysWithValues: artifacts.map { artifact in
            let finalURL = artifactFileURL(artifact)
            return (artifact.fileName, max(fileSize(finalURL), fileSize(finalURL.appendingPathExtension("part"))))
        })
        let downloadedArtifactCount = artifacts.filter { artifactIsReady($0) }.count
        let modelIsComplete = !artifacts.isEmpty && downloadedArtifactCount == artifacts.count
        let modelBytes = sizesByFileName.values.reduce(0, +)
        let modelURL = artifactFileURL(choice.mainArtifact)
        let owners = listeningPorts.processIDs(on: port)
        let ownedProcess = owners.compactMap { processTable.processes[$0] }
            .first(where: { managedChoice(for: $0.command) != nil })
            ?? processTable.processes.values.first(where: { managedChoice(for: $0.command) != nil })
        let residentBytes = ownedProcess.map {
            processTable.residentBytes(rootPIDs: [$0.pid])
        } ?? 0

        var healthDetail: String?
        let requestsProcessing = 0
        let promptTokensPerSecond: Double? = nil
        let predictedTokensPerSecond: Double? = nil
        var isSleeping = false
        var healthIsReady = false

        let ownedProcessIsListening = ownedProcess.map { owners.contains($0.pid) } ?? false
        if ownedProcessIsListening {
            // llama.cpp exempts health and props from its idle timer. Metrics
            // is not exempt, so polling it every refresh would keep a large
            // model resident forever and defeat --sleep-idle-seconds.
            async let healthRequest = fetch(path: Self.sleepSafeMonitoringPaths[0])
            async let propsRequest = fetch(path: Self.sleepSafeMonitoringPaths[1])
            let (health, props) = await (healthRequest, propsRequest)
            healthIsReady = health.statusCode == 200
            healthDetail = health.body.nilIfBlank

            if let data = props.body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isSleeping = Self.boolValue(named: "is_sleeping", in: object) ?? false
            }

        }

        let status: LocalModelStatus
        if runtime == nil {
            status = .runtimeMissing
        } else if choice.downloadURL == nil {
            status = .awaitingWeights
        } else if isDownloading {
            status = .downloading
        } else if let ownedProcess {
            if !ownedProcessIsListening {
                status = .starting
            } else if isSleeping {
                status = .sleeping
            } else if healthIsReady {
                status = .ready
            } else {
                status = .error
            }
            healthDetail = healthDetail ?? "PID \(ownedProcess.pid)"
        } else if !modelIsComplete {
            status = .notDownloaded
        } else {
            status = .stopped
        }

        return LocalModelSnapshot(
            selectedModel: choice,
            profile: profile,
            featureProfile: features,
            status: status,
            runtimeExecutablePath: runtime?.path,
            endpoint: "http://127.0.0.1:\(port)/v1",
            port: port,
            processPID: ownedProcess?.pid,
            residentBytes: residentBytes,
            modelFilePath: modelIsComplete ? modelURL.path : nil,
            modelFileBytes: modelBytes,
            requiredArtifactCount: artifacts.count,
            downloadedArtifactCount: downloadedArtifactCount,
            logPath: logURL.path,
            redactedLogTail: LogSanitizer.sanitize(logTail.read(path: logURL.path), maximumLines: 160),
            healthDetail: healthDetail,
            requestsProcessing: requestsProcessing,
            promptTokensPerSecond: promptTokensPerSecond,
            predictedTokensPerSecond: predictedTokensPerSecond
        )
    }

    func installRuntime() async throws -> CommandResult {
        if let runtimeExecutable {
            return CommandResult(
                command: runtimeExecutable.path,
                exitCode: 0,
                standardOutput: "llama.cpp is already installed.",
                standardError: ""
            )
        }
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let result = try await runner.run(executable: brew, arguments: ["install", "llama.cpp"])
        guard result.succeeded else {
            throw LocalModelServiceError.commandFailed(result.combinedOutput.nilIfBlank ?? "Homebrew could not install llama.cpp.")
        }
        return result
    }

    func downloadSelectedModel() async throws -> CommandResult {
        let choice = selectedChoice
        let artifacts = choice.requiredArtifacts(for: selectedFeatureProfile)
        guard !artifacts.isEmpty else {
            throw LocalModelServiceError.weightsUnavailable
        }
        try prepareDirectories()
        if artifacts.allSatisfy({ artifactIsReady($0) }) {
            return CommandResult(
                command: artifacts.map(\.fileName).joined(separator: ", "),
                exitCode: 0,
                standardOutput: "All selected model artifacts are already downloaded and verified.",
                standardError: ""
            )
        }

        isDownloading = true
        defer { isDownloading = false }
        var outputs: [String] = []
        for artifact in artifacts where !artifactIsReady(artifact) {
            let destination = artifactFileURL(artifact)
            let partial = destination.appendingPathExtension("part")
            appendLog("Downloading \(artifact.fileName) for \(choice.title)")
            if !Self.isArtifactComplete(artifact, bytes: fileSize(partial)) {
                let result = try await runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/curl"),
                    arguments: [
                        "--location", "--fail", "--show-error", "--silent",
                        "--continue-at", "-",
                        "--output", partial.path,
                        artifact.downloadURL.absoluteString,
                    ]
                )
                guard result.succeeded else {
                    appendLog("Download failed: \(result.combinedOutput)")
                    throw LocalModelServiceError.commandFailed(
                        result.combinedOutput.nilIfBlank ?? "Model download failed."
                    )
                }
                outputs.append(result.combinedOutput)
            }
            guard Self.isArtifactComplete(artifact, bytes: fileSize(partial)) else {
                appendLog("Download was smaller than expected; keeping the resumable partial file.")
                throw LocalModelServiceError.commandFailed(
                    "\(artifact.fileName) is incomplete and was kept for a safe resume."
                )
            }
            if !artifact.sha256.isEmpty {
                let digest = try Self.sha256(of: partial)
                guard digest == artifact.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    appendLog("Checksum verification failed for \(artifact.fileName); removed the partial file.")
                    throw LocalModelServiceError.commandFailed(
                        "Checksum verification failed for \(artifact.fileName). The invalid download was removed."
                    )
                }
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            if !artifact.sha256.isEmpty {
                try artifact.sha256.write(
                    to: verificationURL(for: artifact),
                    atomically: true,
                    encoding: .utf8
                )
            }
            appendLog("Download verified: \(artifact.fileName)")
        }
        return CommandResult(
            command: artifacts.map(\.fileName).joined(separator: ", "),
            exitCode: 0,
            standardOutput: outputs.filter { !$0.isEmpty }.joined(separator: "\n"),
            standardError: ""
        )
    }

    func start(memory: SystemMemorySnapshot) async throws {
        let choice = selectedChoice
        if let reason = Self.startBlockReason(choice: choice, memory: memory) {
            throw LocalModelServiceError.commandFailed(reason)
        }
        guard managedProcess == nil else { throw LocalModelServiceError.alreadyRunning }
        guard let executable = runtimeExecutable else { throw LocalModelServiceError.runtimeMissing }
        guard choice.downloadURL != nil else { throw LocalModelServiceError.weightsUnavailable }
        let artifacts = choice.requiredArtifacts(for: selectedFeatureProfile)
        guard !artifacts.isEmpty, artifacts.allSatisfy({ artifactIsReady($0) }) else {
            throw LocalModelServiceError.modelNotDownloaded
        }
        let (table, _) = try await inspection.capture()
        guard !table.processes.values.contains(where: { managedChoice(for: $0.command) != nil }) else {
            throw LocalModelServiceError.alreadyRunning
        }

        try prepareDirectories()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.launchArguments(
            choice: choice,
            profile: selectedProfile,
            features: selectedFeatureProfile,
            modelsDirectory: modelsDirectory,
            port: port
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] finished in
            try? logHandle.close()
            Task { await self?.processDidTerminate(pid: Int(finished.processIdentifier)) }
        }
        appendLog("Starting \(choice.title) with \(selectedProfile.title)")
        try process.run()
        managedProcess = process
        try String(process.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
    }

    func stop() async throws {
        let (table, _) = try await inspection.capture()
        guard let savedPID = (try? String(contentsOf: pidURL, encoding: .utf8))?.nilIfBlank.flatMap(Int.init),
              let process = table.processes[savedPID],
              managedChoice(for: process.command) != nil else {
            throw LocalModelServiceError.notOwned
        }
        guard Darwin.kill(pid_t(savedPID), SIGTERM) == 0 || errno == ESRCH else {
            throw LocalModelServiceError.commandFailed("Could not gracefully stop local model PID \(savedPID) (errno \(errno)).")
        }
        appendLog("Sent graceful stop to PID \(savedPID)")
        managedProcess = nil
        try? FileManager.default.removeItem(at: pidURL)
    }

    private var selectedChoice: LocalModelChoice {
        UserDefaults.standard.string(forKey: PreferenceKeys.localModelChoice)
            .flatMap(LocalModelChoice.init(rawValue:)) ?? .qwen36_27B_Q4
    }

    private var selectedProfile: LocalModelProfile {
        UserDefaults.standard.string(forKey: PreferenceKeys.localModelProfile)
            .flatMap(LocalModelProfile.init(rawValue:)) ?? .standard
    }

    private var selectedFeatureProfile: LocalModelFeatureProfile {
        let saved = UserDefaults.standard.string(forKey: PreferenceKeys.localModelFeatureProfile)
            .flatMap(LocalModelFeatureProfile.init(rawValue:)) ?? .accelerated
        return selectedChoice.supportedFeatureProfiles.contains(saved) ? saved : .textOnly
    }

    private var runtimeExecutable: URL? {
        [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ]
        .map(URL.init(fileURLWithPath:))
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func modelFileURL(for choice: LocalModelChoice) -> URL? {
        choice.fileName.map { modelsDirectory.appendingPathComponent($0) }
    }

    private func artifactFileURL(_ artifact: LocalModelArtifact) -> URL {
        modelsDirectory.appendingPathComponent(artifact.fileName)
    }

    private func verificationURL(for artifact: LocalModelArtifact) -> URL {
        artifactFileURL(artifact).appendingPathExtension("sha256")
    }

    private func artifactIsReady(_ artifact: LocalModelArtifact) -> Bool {
        guard Self.isArtifactComplete(artifact, bytes: fileSize(artifactFileURL(artifact))) else {
            return false
        }
        guard !artifact.sha256.isEmpty else { return true }
        return (try? String(contentsOf: verificationURL(for: artifact), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == artifact.sha256
    }

    private func isManagedCommand(_ command: String, choice: LocalModelChoice) -> Bool {
        guard let model = modelFileURL(for: choice) else { return false }
        return Self.isManagedCommand(command, modelPath: model.path, port: port)
    }

    private func managedChoice(for command: String) -> LocalModelChoice? {
        LocalModelChoice.allCases.first(where: { isManagedCommand(command, choice: $0) })
    }

    static func isManagedCommand(_ command: String, modelPath: String, port: Int) -> Bool {
        command.contains("llama-server")
            && command.contains(modelPath)
            && command.contains("--port \(port)")
    }

    static func launchArguments(
        choice: LocalModelChoice,
        profile: LocalModelProfile,
        features requestedFeatures: LocalModelFeatureProfile,
        modelsDirectory: URL,
        port: Int
    ) -> [String] {
        let features = choice.supportedFeatureProfiles.contains(requestedFeatures)
            ? requestedFeatures
            : .textOnly
        let artifacts = choice.requiredArtifacts(for: features)
        guard let main = artifacts.first(where: { $0.role == .main }) else { return [] }
        var arguments = [
            "-m", modelsDirectory.appendingPathComponent(main.fileName).path,
            "--ctx-size", String(profile.contextSize),
            "-np", "1",
            "--n-gpu-layers", "all",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            "--flash-attn", "on",
            // Muse reloads in a few seconds on Apple Silicon; returning its
            // large unified-memory allocation quickly is a better default
            // than keeping it warm while cloud managers are idle.
            "--sleep-idle-seconds", "180",
            "--metrics",
            "--jinja",
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        if choice.isMuseGlimmer {
            arguments += [
                "--alias", "muse-glimmer",
                "--temp", "1.0",
                "--top-p", "0.95",
                "--top-k", "64",
            ]
        }
        if let vision = artifacts.first(where: { $0.role == .vision }) {
            arguments += ["--mmproj", modelsDirectory.appendingPathComponent(vision.fileName).path]
        }
        if let draft = artifacts.first(where: { $0.role == .draft }) {
            arguments += [
                "--model-draft", modelsDirectory.appendingPathComponent(draft.fileName).path,
                "--spec-type", "draft-dflash",
                "--spec-draft-n-max", "16",
            ]
        }
        return arguments
    }

    private func fileSize(_ url: URL?) -> UInt64 {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.uint64Value
    }

    static func isModelComplete(choice: LocalModelChoice, bytes: UInt64) -> Bool {
        guard let expected = choice.expectedDownloadBytes else { return false }
        return bytes >= expected * 95 / 100
    }

    static func isArtifactComplete(_ artifact: LocalModelArtifact, bytes: UInt64) -> Bool {
        if artifact.sha256.isEmpty {
            return bytes >= artifact.expectedBytes * 95 / 100
        }
        return bytes >= artifact.expectedBytes
    }

    static func artifactsAreComplete(
        _ artifacts: [LocalModelArtifact],
        sizesByFileName: [String: UInt64]
    ) -> Bool {
        !artifacts.isEmpty && artifacts.allSatisfy { artifact in
            isArtifactComplete(artifact, bytes: sizesByFileName[artifact.fileName] ?? 0)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func startBlockReason(
        choice: LocalModelChoice,
        memory: SystemMemorySnapshot
    ) -> String? {
        guard memory.pressureReservePercentage >= 20 else {
            return "Memory pressure is critical. Local Rig will not load another model."
        }
        guard memory.totalBytes >= choice.minimumSystemMemoryBytes else {
            let requiredGB = choice.minimumSystemMemoryBytes / 1_000_000_000
            let availableGB = memory.totalBytes / 1_000_000_000
            return "\(choice.title) targets at least \(requiredGB) GB of unified memory; this Mac reports \(availableGB) GB."
        }
        return nil
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    private func appendLog(_ message: String) {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func fetch(path: String) async -> (statusCode: Int?, body: String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return (nil, "") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode, String(decoding: data, as: UTF8.self))
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func processDidTerminate(pid: Int) {
        if managedProcess.map({ Int($0.processIdentifier) }) == pid {
            managedProcess = nil
        }
        if (try? String(contentsOf: pidURL, encoding: .utf8))?.nilIfBlank == String(pid) {
            try? FileManager.default.removeItem(at: pidURL)
        }
    }

    static func metric(_ name: String, in text: String) -> Double? {
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(name), !value.hasPrefix("#") else { continue }
            if let last = value.split(whereSeparator: \.isWhitespace).last,
               let number = Double(last) {
                return number
            }
        }
        return nil
    }

    private static func boolValue(named key: String, in object: Any) -> Bool? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? Bool { return value }
            for value in dictionary.values {
                if let found = boolValue(named: key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = boolValue(named: key, in: value) { return found }
            }
        }
        return nil
    }
}
