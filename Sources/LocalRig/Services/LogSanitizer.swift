import Foundation

enum LogSanitizer {
    private static let patterns: [(NSRegularExpression, String)] = [
        (regex(#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#), "$1<redacted>"),
        (regex(#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/-]+"#), "$1 <redacted>"),
        (regex(#"\bAIza[A-Za-z0-9_-]{20,}\b"#), "<redacted-google-key>"),
        (regex(#"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#), "<redacted-jwt>"),
        (regex(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#), "<redacted-email>"),
        (regex(#"(?i)((?:--api[_-]?key|--access[_-]?token|--refresh[_-]?token|--token|--secret|--password)(?:=|\s+))(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#), "$1<redacted>"),
        (regex(#"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|private[_-]?key)\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#), "$1<redacted>"),
        (regex(#"(?i)(cookie\s*:\s*)[^\r\n]+"#), "$1<redacted>"),
    ]

    static func sanitize(_ value: String, maximumLines: Int = 250, maximumCharacters: Int = 80_000) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        var result = lines.suffix(maximumLines).joined(separator: "\n")
        if result.count > maximumCharacters {
            result = String(result.suffix(maximumCharacters))
            if let newline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newline)...])
            }
        }
        for (expression, replacement) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants. Returning a never-matching expression
        // preserves fail-closed redaction behavior if one is edited incorrectly.
        (try? NSRegularExpression(pattern: pattern))
            ?? (try! NSRegularExpression(pattern: #"(?!)"#))
    }
}
