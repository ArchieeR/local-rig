import Foundation

struct WorkspaceResolver: Sendable {
    func resolve(configuredPath: String?) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let configuredPath = configuredPath?.nilIfBlank {
            candidates.append(URL(fileURLWithPath: configuredPath, isDirectory: true))
        }
        if let environmentPath = ProcessInfo.processInfo.environment["RHEOS_REPOS_ROOT"]?.nilIfBlank {
            candidates.append(URL(fileURLWithPath: environmentPath, isDirectory: true))
        }

        candidates.append(contentsOf: ancestors(of: Bundle.main.bundleURL))
        candidates.append(contentsOf: ancestors(of: URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )))
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/rheos-repos", isDirectory: true)
        )
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/rheos-repos", isDirectory: true)
        )
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/ALDR Ltd/Rheos/Code/rheos-repos", isDirectory: true)
        )

        return candidates.first { candidate in
            fileManager.fileExists(atPath: candidate.appendingPathComponent("scripts/qa-rig.sh").path)
                || fileManager.fileExists(atPath: candidate.appendingPathComponent("scripts/rig2.sh").path)
        }
    }

    private func ancestors(of start: URL) -> [URL] {
        var results: [URL] = []
        var current = start.standardizedFileURL
        for _ in 0..<10 {
            results.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return results
    }
}
