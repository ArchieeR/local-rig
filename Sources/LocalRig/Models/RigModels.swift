import Foundation

enum SidebarSelection: Hashable, Sendable {
    case home
    case runtime
    case localModels
    case rigs
    case devServers
    case mcps
    case rig(Int)
}

enum RigMode: String, Codable, CaseIterable, Sendable {
    case shared
    case isolated = "iso"

    var title: String {
        switch self {
        case .shared: "Shared"
        case .isolated: "Isolated"
        }
    }
}

enum RigProfile: String, Codable, CaseIterable, Sendable {
    case fast = "emu-fast"
    case real = "emu-real"
    case live = "emu-live"

    var title: String {
        switch self {
        case .fast: "Fast · AI off"
        case .real: "Real · AI on"
        case .live: "Live scrape"
        }
    }
}

enum RigController: String, Codable, Sendable {
    case legacy = "qa-rig"
    case rig2
}

enum RigServiceKind: String, Codable, CaseIterable, Sendable {
    case dev = "Dev server"
    case firestore = "Firestore"
    case auth = "Auth"
    case functions = "Functions"
    case storage = "Storage"
    case emulatorUI = "Emulator UI"

    var systemImage: String {
        switch self {
        case .dev: "network"
        case .firestore: "cylinder.split.1x2"
        case .auth: "person.badge.key"
        case .functions: "function"
        case .storage: "externaldrive"
        case .emulatorUI: "rectangle.3.group"
        }
    }
}

struct LocalProcess: Codable, Hashable, Identifiable, Sendable {
    let pid: Int
    let parentPID: Int
    let residentBytes: UInt64
    let cpuPercent: Double
    let elapsed: String
    let command: String

    var id: Int { pid }
}

enum AgentFamily: String, Codable, Hashable, Sendable {
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case claudeDesktop = "Claude Desktop"

    var systemImage: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .claudeDesktop: "bubble.left.and.bubble.right"
        }
    }
}

enum RuntimeComponentKind: String, Codable, Hashable, Sendable {
    case taskRuntime = "Task runtime"
    case mcp = "MCP"
    case browser = "Browser MCP"
    case devServer = "Dev process"
    case helper = "Helper"
}

struct RuntimeComponent: Codable, Hashable, Identifiable, Sendable {
    let rootPID: Int
    let name: String
    let kind: RuntimeComponentKind
    let processes: [LocalProcess]
    let repositoryPath: String?
    let listeningPorts: [Int]
    let staleReasons: [String]

    var id: Int { rootPID }
    var residentBytes: UInt64 { processes.reduce(0) { $0 + $1.residentBytes } }
    var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    var nodeProcessCount: Int { processes.filter(\.isNodeLike).count }
    var isStaleCandidate: Bool { !staleReasons.isEmpty }
}

struct AgentSessionGroup: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let family: AgentFamily
    let title: String
    let hostPID: Int
    let taskRuntimePIDs: [Int]
    let activeSessionCount: Int
    let inactiveSessionCount: Int
    let ageSeconds: UInt64
    let repositoryPaths: [String]
    let components: [RuntimeComponent]
    let staleReasons: [String]

    var estimatedSessionCount: Int { activeSessionCount + inactiveSessionCount }
    var residentBytes: UInt64 { components.reduce(0) { $0 + $1.residentBytes } }
    var cpuPercent: Double { components.reduce(0) { $0 + $1.cpuPercent } }
    var mcpCount: Int { components.filter { $0.kind == .mcp || $0.kind == .browser }.count }
    var nodeProcessCount: Int { components.reduce(0) { $0 + $1.nodeProcessCount } }
    var isStaleCandidate: Bool { !staleReasons.isEmpty }
}

struct AgentHostSnapshot: Codable, Hashable, Identifiable, Sendable {
    let family: AgentFamily
    let rootPID: Int
    let processCount: Int
    let residentBytes: UInt64
    let cpuPercent: Double

    var id: String { "\(family.rawValue)-\(rootPID)" }
}

enum DevServerOwnerKind: String, Codable, Hashable, Sendable {
    case rig
    case agentSession
    case claudeDesktop
    case terminal
    case unassigned
}

struct DevServerSnapshot: Codable, Hashable, Identifiable, Sendable {
    let port: Int
    let rootPID: Int
    let listenerPIDs: [Int]
    let processes: [LocalProcess]
    let repositoryPath: String?
    let ownerKind: DevServerOwnerKind
    let ownerLabel: String
    let sessionID: String?
    let ageSeconds: UInt64

    var id: String { "\(port)-\(rootPID)" }
    var residentBytes: UInt64 { processes.reduce(0) { $0 + $1.residentBytes } }
    var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
}

struct MCPUsageSnapshot: Hashable, Identifiable, Sendable {
    let name: String
    let kind: RuntimeComponentKind
    let instanceCount: Int
    let processCount: Int
    let residentBytes: UInt64
    let cpuPercent: Double
    let sessionIDs: [String]
    let sessionTitles: [String]

    var id: String { "\(kind.rawValue)-\(name)" }
    var sessionCount: Int { sessionIDs.count }
}

struct AgentRuntimeSnapshot: Codable, Hashable, Sendable {
    let hosts: [AgentHostSnapshot]
    let sessions: [AgentSessionGroup]
    let unassignedComponents: [RuntimeComponent]
    let devServers: [DevServerSnapshot]

    var estimatedSessionCount: Int { sessions.reduce(0) { $0 + $1.estimatedSessionCount } }
    var activeSessionCount: Int { sessions.reduce(0) { $0 + $1.activeSessionCount } }
    var mcpCount: Int {
        sessions.reduce(0) { $0 + $1.mcpCount }
            + unassignedComponents.filter { $0.kind == .mcp || $0.kind == .browser }.count
    }
    var nodeProcessCount: Int {
        sessions.reduce(0) { $0 + $1.nodeProcessCount }
            + unassignedComponents.reduce(0) { $0 + $1.nodeProcessCount }
    }
    var residentBytes: UInt64 { hosts.reduce(0) { $0 + $1.residentBytes } }
    var staleCandidateCount: Int {
        sessions.filter(\.isStaleCandidate).count
            + unassignedComponents.filter(\.isStaleCandidate).count
    }

    var mcpUsageByType: [MCPUsageSnapshot] {
        var result: [String: MCPUsageSnapshot] = [:]
        let sessionComponents = sessions.flatMap { session in
            session.components.map { ($0, session.id as String?, session.title as String?) }
        }
        let unassigned = unassignedComponents.map { ($0, nil as String?, nil as String?) }

        for (component, sessionID, sessionTitle) in sessionComponents + unassigned
        where component.kind == .mcp || component.kind == .browser {
            let key = "\(component.kind.rawValue)-\(component.name)"
            let existing = result[key]
            let sessionIDs = Set(existing?.sessionIDs ?? []).union(sessionID.map { [$0] } ?? [])
            let sessionTitles = Set(existing?.sessionTitles ?? []).union(sessionTitle.map { [$0] } ?? [])
            result[key] = MCPUsageSnapshot(
                name: component.name,
                kind: component.kind,
                instanceCount: (existing?.instanceCount ?? 0) + 1,
                processCount: (existing?.processCount ?? 0) + component.processes.count,
                residentBytes: (existing?.residentBytes ?? 0) + component.residentBytes,
                cpuPercent: (existing?.cpuPercent ?? 0) + component.cpuPercent,
                sessionIDs: sessionIDs.sorted(),
                sessionTitles: sessionTitles.sorted()
            )
        }
        return result.values.sorted {
            if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct RigServiceStatus: Codable, Hashable, Identifiable, Sendable {
    let kind: RigServiceKind
    let port: Int
    let isListening: Bool
    let processes: [LocalProcess]
    let isShared: Bool

    var id: RigServiceKind { kind }
}

struct RepositoryIdentity: Codable, Hashable, Sendable {
    let path: String
    let exists: Bool
    let branch: String?
    let commit: String?
    let summary: String?

    var displayRevision: String {
        if let branch, !branch.isEmpty {
            return branch
        }
        if let commit {
            return "detached · \(commit)"
        }
        return "not available"
    }
}

struct RigSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let holder: String?
    let mode: RigMode
    let profile: RigProfile
    let controller: RigController
    let repository: RepositoryIdentity
    let backendRepository: RepositoryIdentity
    let services: [RigServiceStatus]
    let devResidentBytes: UInt64
    let emulatorResidentBytes: UInt64
    let devLogPath: String
    let emulatorLogPath: String
    let devLogTail: String
    let emulatorLogTail: String

    var devPort: Int { 2_999 + id }
    var devIsRunning: Bool {
        services.first(where: { $0.kind == .dev })?.isListening == true
    }
    var emulatorIsRunning: Bool {
        services.first(where: { $0.kind == .firestore })?.isListening == true
            && services.first(where: { $0.kind == .functions })?.isListening == true
    }
    var displayName: String { "Rig \(id)" }
}

struct SystemMemorySnapshot: Codable, Hashable, Sendable {
    let totalBytes: UInt64
    let physicalOccupiedBytes: UInt64
    let physicalUnusedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let pressureReservePercentage: Double

    var pressureStatus: String {
        switch pressureReservePercentage {
        case 50...: "Normal"
        case 20..<50: "Elevated"
        default: "Critical"
        }
    }
}

enum LocalModelStatus: String, Codable, Hashable, Sendable {
    case runtimeMissing
    case awaitingWeights
    case notDownloaded
    case downloading
    case stopped
    case starting
    case ready
    case busy
    case sleeping
    case error

    var title: String {
        switch self {
        case .runtimeMissing: "Runtime missing"
        case .awaitingWeights: "Awaiting weights"
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready: "Ready"
        case .busy: "Busy"
        case .sleeping: "Sleeping"
        case .error: "Needs attention"
        }
    }

    var isRunning: Bool {
        switch self {
        case .downloading, .starting, .ready, .busy, .sleeping: true
        default: false
        }
    }
}

enum LocalModelProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case economy
    case standard
    case deep

    var id: Self { self }
    var title: String {
        switch self {
        case .economy: "Economy · 16k"
        case .standard: "Standard · 32k"
        case .deep: "Deep · 64k"
        }
    }
    var contextSize: Int {
        switch self {
        case .economy: 16_384
        case .standard: 32_768
        case .deep: 65_536
        }
    }
}

enum LocalModelFeatureProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case textOnly
    case accelerated
    case vision
    case full

    var id: Self { self }
    var title: String {
        switch self {
        case .textOnly: "Text"
        case .accelerated: "Fast"
        case .vision: "Vision"
        case .full: "Full"
        }
    }

    var requiresVision: Bool { self == .vision || self == .full }
    var requiresDraft: Bool { self == .accelerated || self == .full }
}

enum LocalModelArtifactRole: String, Codable, Hashable, Sendable {
    case main
    case vision
    case draft
}

struct LocalModelArtifact: Codable, Hashable, Identifiable, Sendable {
    let role: LocalModelArtifactRole
    let repository: String
    let fileName: String
    let expectedBytes: UInt64
    let sha256: String

    var id: String { "\(repository)/\(fileName)" }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)?download=true")!
    }
}

enum LocalModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case museGlimmerDynamic = "muse-glimmer-30b-dynamic"
    case museGlimmer17GB = "muse-glimmer-30b-17gb"
    case qwen36_27B_Q4 = "qwen3.6-27b-q4-k-m"
    case qwen38_27B = "qwen3.8-27b"
    case qwen38Max = "qwen3.8-max"

    var id: Self { self }
    var title: String {
        switch self {
        case .museGlimmerDynamic: "Muse Glimmer 30B · Dynamic"
        case .museGlimmer17GB: "Muse Glimmer 30B · 17 GB"
        case .qwen36_27B_Q4: "Qwen3.6 27B · Q4_K_M"
        case .qwen38_27B: "Qwen3.8 27B"
        case .qwen38Max: "Qwen3.8 Max"
        }
    }
    var detail: String {
        switch self {
        case .museGlimmerDynamic: "Official Meta GGUF · 0.2% reported average degradation · 32 GB target"
        case .museGlimmer17GB: "Official Meta GGUF · compact fallback · 24 GB target"
        case .qwen36_27B_Q4: "Runnable baseline · 18 GB community GGUF from official Qwen weights"
        case .qwen38_27B: "Target upgrade · waiting for verified weights and GGUF"
        case .qwen38Max: "Frontier-size model · not compatible with a 48 GB local machine"
        }
    }

    var minimumSystemMemoryBytes: UInt64 {
        switch self {
        case .museGlimmerDynamic: 32_000_000_000
        case .museGlimmer17GB, .qwen36_27B_Q4: 24_000_000_000
        case .qwen38_27B, .qwen38Max: .max
        }
    }

    var mainArtifact: LocalModelArtifact {
        switch self {
        case .museGlimmerDynamic:
            LocalModelArtifact(
                role: .main,
                repository: "meta-models/Muse-Glimmer-30B-GGUF",
                fileName: "muse-glimmer-30B-kquant-dynamic.gguf",
                expectedBytes: 19_653_957_984,
                sha256: "513109c8319115f69eb09fb7b118c97c8167d15bc014fd7670d2e30489bf106c"
            )
        case .museGlimmer17GB:
            LocalModelArtifact(
                role: .main,
                repository: "meta-models/Muse-Glimmer-30B-GGUF",
                fileName: "muse-glimmer-30B-kquant-17gb.gguf",
                expectedBytes: 16_756_681_056,
                sha256: "7e9b74b7c8875e9e265695df9613bf6290f2392e479ce740495a129019c488d8"
            )
        case .qwen36_27B_Q4:
            LocalModelArtifact(
                role: .main,
                repository: "bartowski/Qwen_Qwen3.6-27B-GGUF",
                fileName: "Qwen_Qwen3.6-27B-Q4_K_M.gguf",
                expectedBytes: 17_980_000_000,
                sha256: ""
            )
        case .qwen38_27B, .qwen38Max:
            LocalModelArtifact(role: .main, repository: "", fileName: "", expectedBytes: 0, sha256: "")
        }
    }

    private var visionArtifact: LocalModelArtifact? {
        guard isMuseGlimmer else { return nil }
        return LocalModelArtifact(
            role: .vision,
            repository: "meta-models/Muse-Glimmer-30B-GGUF",
            fileName: "mmproj-kquant.gguf",
            expectedBytes: 1_400_328_928,
            sha256: "f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6"
        )
    }

    private var draftArtifact: LocalModelArtifact? {
        guard isMuseGlimmer else { return nil }
        return LocalModelArtifact(
            role: .draft,
            repository: "meta-models/Muse-Glimmer-30B-GGUF",
            fileName: "dflash-kquant.gguf",
            expectedBytes: 1_631_205_312,
            sha256: "27d9a805fa29b943cfb6ad4843367cd4eaaaf06bd452d8cc3e00a2cd18a677bc"
        )
    }

    var isMuseGlimmer: Bool {
        self == .museGlimmerDynamic || self == .museGlimmer17GB
    }

    var supportedFeatureProfiles: [LocalModelFeatureProfile] {
        // The official Meta GGUF currently loads in llama.cpp for text and
        // vision, but its array-encoded sliding-window metadata crashes the
        // DFlash bind path (llama.cpp #26894). Keep the downloaded drafter for
        // a future runtime fix without advertising an unsafe launch mode.
        isMuseGlimmer ? [.textOnly, .vision] : [.textOnly]
    }

    func requiredArtifacts(for features: LocalModelFeatureProfile) -> [LocalModelArtifact] {
        guard !mainArtifact.fileName.isEmpty else { return [] }
        var artifacts = [mainArtifact]
        if features.requiresVision, let visionArtifact { artifacts.append(visionArtifact) }
        if features.requiresDraft, let draftArtifact { artifacts.append(draftArtifact) }
        return artifacts
    }
    var huggingFaceID: String? {
        mainArtifact.repository.nilIfBlank
    }
    var fileName: String? {
        mainArtifact.fileName.nilIfBlank
    }
    var downloadURL: URL? {
        guard let huggingFaceID, let fileName else { return nil }
        return URL(string: "https://huggingface.co/\(huggingFaceID)/resolve/main/\(fileName)?download=true")
    }
    var expectedDownloadBytes: UInt64? {
        mainArtifact.expectedBytes == 0 ? nil : mainArtifact.expectedBytes
    }
}

struct LocalModelSnapshot: Codable, Hashable, Sendable {
    let selectedModel: LocalModelChoice
    let profile: LocalModelProfile
    let featureProfile: LocalModelFeatureProfile
    let status: LocalModelStatus
    let runtimeExecutablePath: String?
    let endpoint: String
    let port: Int
    let processPID: Int?
    let residentBytes: UInt64
    let modelFilePath: String?
    let modelFileBytes: UInt64
    let requiredArtifactCount: Int
    let downloadedArtifactCount: Int
    let logPath: String
    let redactedLogTail: String
    let healthDetail: String?
    let requestsProcessing: Int
    let promptTokensPerSecond: Double?
    let predictedTokensPerSecond: Double?

    var runtimeInstalled: Bool { runtimeExecutablePath != nil }
    var modelDownloaded: Bool { modelFilePath != nil }
}

struct DashboardSnapshot: Codable, Hashable, Sendable {
    let capturedAt: Date
    let workspaceRoot: String
    let rig2IsVerified: Bool
    let systemMemory: SystemMemorySnapshot
    let rigs: [RigSnapshot]
    let agentRuntime: AgentRuntimeSnapshot
    let localModel: LocalModelSnapshot
}

enum RigCommand: Equatable, Sendable {
    case status
    case doctor
    case claim(String)
    case release
    case startShared
    case startIsolated
    case stopDev
    case startEmulator
    case stopEmulator
    case rebuild

    var title: String {
        switch self {
        case .status: "Status"
        case .doctor: "Run doctor"
        case .claim: "Claim rig"
        case .release: "Release rig"
        case .startShared: "Start shared"
        case .startIsolated: "Start isolated"
        case .stopDev: "Stop dev server"
        case .startEmulator: "Start emulator"
        case .stopEmulator: "Stop emulator"
        case .rebuild: "Rebuild functions"
        }
    }

    var arguments: [String] {
        switch self {
        case .status: ["status"]
        case .doctor: ["doctor"]
        case let .claim(name): ["claim", name]
        case .release: ["release"]
        case .startShared: ["up", "--shared"]
        case .startIsolated: ["up", "--iso"]
        case .stopDev: ["down"]
        case .startEmulator: ["emu-up"]
        case .stopEmulator: ["emu-down"]
        case .rebuild: ["rebuild"]
        }
    }

    var requiresRig2: Bool {
        switch self {
        case .startIsolated:
            true
        default:
            false
        }
    }
}

struct CommandResult: Sendable {
    let command: String
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: standardOutput.isEmpty || standardError.isEmpty ? "" : "\n")
    }
}

struct CommandLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let rigID: Int
    let title: String
    let result: CommandResult
}

extension LocalProcess {
    var isNodeLike: Bool {
        let executable = command.split(whereSeparator: \ .isWhitespace).first.map(String.init)?.lowercased() ?? ""
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return name == "node" || name == "npm" || name == "npx" || name == "node_repl"
    }
}
