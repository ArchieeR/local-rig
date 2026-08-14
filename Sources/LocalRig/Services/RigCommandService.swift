import Foundation

enum RigCommandError: LocalizedError {
    case rig2Disabled
    case missingScript(String)
    case invalidClaimName

    var errorDescription: String? {
        switch self {
        case .rig2Disabled:
            "Rig 2 controls are disabled. Enable them in Settings only after reviewing the unverified-controller warning."
        case let .missingScript(path):
            "Rig controller script is missing at \(path)."
        case .invalidClaimName:
            "Claim names may contain only letters, numbers, dot, underscore, and dash (1–48 characters)."
        }
    }
}

struct RigCommandService: Sendable {
    private let runner = ProcessRunner()

    func run(
        _ command: RigCommand,
        rigID: Int,
        workspaceRoot root: URL,
        rig2ControlsEnabled: Bool,
        sessionName: String
    ) async throws -> CommandResult {
        let controller: RigController
        if rigID == 1 && !rig2ControlsEnabled {
            controller = .legacy
        } else {
            guard rig2ControlsEnabled else { throw RigCommandError.rig2Disabled }
            controller = .rig2
        }

        guard Self.isValidClaimName(sessionName) else {
            throw RigCommandError.invalidClaimName
        }
        if case let .claim(name) = command, name != sessionName {
            throw RigCommandError.invalidClaimName
        }

        let relativeScript = controller == .legacy ? "scripts/qa-rig.sh" : "scripts/rig2.sh"
        let script = root.appendingPathComponent(relativeScript)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw RigCommandError.missingScript(script.path)
        }

        var arguments = [script.path]
        if controller == .rig2 { arguments.append(String(rigID)) }
        arguments.append(contentsOf: command.arguments)
        return try await runner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            currentDirectoryURL: root,
            environment: ["QA_SESSION": sessionName]
        )
    }

    static func isValidClaimName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]{1,48}$"#, options: .regularExpression) != nil
    }

    static func normalizedSessionName() -> String {
        let raw = ProcessInfo.processInfo.environment["USER"] ?? "rig-app"
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "-"
        }
        let value = String(allowed).prefix(36)
        return value.isEmpty ? "rig-app" : "\(value)-rig-app"
    }
}
