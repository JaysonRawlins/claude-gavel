import Foundation

/// Reads the latest session title from a Claude Code JSONL transcript. Catches
/// both `/rename` events and `--name`-set titles. Best-effort: read errors,
/// missing files, and malformed lines all return nil.
enum JsonlRenameReader {
    static func latestRename(cwd: String, sessionId: String) -> String? {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects")
            .appending("/\(encoded)/\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let patterns = [
            #"<command-message>rename</command-message>[\s\S]*?<command-args>(.+?)</command-args>"#,
            #""type":"custom-title","customTitle":"([^"]*)""#
        ]

        var latestEnd = -1
        var latestValue: String? = nil
        let nsRange = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: nsRange) {
                let end = match.range.location + match.range.length
                guard end > latestEnd,
                      match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: text) else { continue }
                latestEnd = end
                latestValue = String(text[captureRange])
            }
        }

        guard let value = latestValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
