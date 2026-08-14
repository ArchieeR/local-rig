import Foundation

enum ANSI {
    private static let expression = try? NSRegularExpression(
        pattern: #"\u001B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#
    )

    static func strip(from value: String) -> String {
        guard let expression else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
