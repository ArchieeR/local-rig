import Foundation

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

struct ProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let outputBuffer = OutputBuffer()
            let errorBuffer = OutputBuffer()

            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.standardInput = FileHandle.nullDevice

            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { outputBuffer.append(data) }
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { errorBuffer.append(data) }
            }

            process.terminationHandler = { finishedProcess in
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
                errorBuffer.append(standardError.fileHandleForReading.readDataToEndOfFile())

                let rendered = ([executable.path] + arguments)
                    .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
                    .joined(separator: " ")
                continuation.resume(returning: CommandResult(
                    command: rendered,
                    exitCode: finishedProcess.terminationStatus,
                    standardOutput: ANSI.strip(from: outputBuffer.string()),
                    standardError: ANSI.strip(from: errorBuffer.string())
                ))
            }

            do {
                try process.run()
            } catch {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
