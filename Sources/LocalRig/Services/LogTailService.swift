import Foundation

struct LogTailService: Sendable {
    func read(path: String, maximumBytes: UInt64 = 180_000) -> String {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "No log file yet.\n\(path)"
        }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > maximumBytes ? end - maximumBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return ANSI.strip(from: text).nilIfBlank ?? "Log is empty.\n\(path)"
    }
}
