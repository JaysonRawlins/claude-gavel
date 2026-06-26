import Foundation

/// Reads a session title from a Claude Code JSONL transcript. `latestRename`
/// catches explicit titles (`/rename`, `--name`); `firstPromptTitle` derives a
/// best-effort name from the opening user prompt when no explicit title exists.
/// Best-effort throughout: read errors, missing files, and malformed lines all
/// return nil.
enum JsonlRenameReader {
    static func latestRename(cwd: String, sessionId: String) -> String? {
        guard let text = transcriptText(cwd: cwd, sessionId: sessionId) else { return nil }

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

    /// Derive a short title from the first real user prompt in the transcript.
    static func firstPromptTitle(cwd: String, sessionId: String) -> String? {
        guard let text = transcriptText(cwd: cwd, sessionId: sessionId) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let prompt = userPromptText(fromLine: String(line)) else { continue }
            if let title = condense(prompt) { return title }
        }
        return nil
    }

    private static let maxTitleLength = 60

    /// Path Claude Code writes a session transcript to: cwd with `/` and `.`
    /// flattened to `-`, under `~/.claude/projects/<encoded>/<sessionId>.jsonl`.
    static func transcriptPath(cwd: String, sessionId: String) -> String {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects")
            .appending("/\(encoded)/\(sessionId).jsonl")
    }

    static func transcriptText(cwd: String, sessionId: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: transcriptPath(cwd: cwd, sessionId: sessionId))) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func userPromptText(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "user",
              (obj["isMeta"] as? Bool) != true,
              let message = obj["message"] as? [String: Any] else { return nil }

        let text: String
        if let str = message["content"] as? String {
            text = str
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        } else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func condense(_ prompt: String) -> String? {
        let collapsed = prompt
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxTitleLength else { return collapsed }

        let clipped = collapsed.prefix(maxTitleLength)
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[..<lastSpace]) + "…"
        }
        return String(clipped) + "…"
    }
}
