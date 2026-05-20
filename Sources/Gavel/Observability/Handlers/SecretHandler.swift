import Foundation

final class SecretHandler: JsonlEventHandler {
    let name = "secret"

    private struct SecretPattern {
        let label: String
        let regex: NSRegularExpression
    }

    private static let patterns: [SecretPattern] = {
        let raw: [(String, String)] = [
            ("AWS access key", #"AKIA[0-9A-Z]{16}"#),
            ("GitHub PAT", #"ghp_[A-Za-z0-9]{36,}"#),
            ("GitHub OAuth token", #"gho_[A-Za-z0-9]{36,}"#),
            ("GitHub server token", #"ghs_[A-Za-z0-9]{36,}"#),
            ("Anthropic API key", #"sk-ant-[A-Za-z0-9_\-]{40,}"#),
            ("OpenAI API key", #"sk-[A-Za-z0-9]{40,}"#),
            ("Slack token", #"xox[bpoa]-[A-Za-z0-9\-]{10,}"#),
            ("Slack webhook URL", #"https://hooks\.slack\.com/services/[A-Z0-9/]{20,}"#)
        ]
        return raw.compactMap { (label, pattern) in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return SecretPattern(label: label, regex: regex)
        }
    }()

    private static let cooldown: TimeInterval = 300

    private var lastFireByLabel: [String: Date] = [:]

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        let line = event.rawLine
        let range = NSRange(line.startIndex..., in: line)
        for pattern in Self.patterns where pattern.regex.firstMatch(in: line, range: range) != nil {
            if let last = lastFireByLabel[pattern.label],
               Date().timeIntervalSince(last) < Self.cooldown {
                return
            }
            lastFireByLabel[pattern.label] = Date()
            let sessionTag = session.label.isEmpty ? "PID \(session.pid)" : session.label
            GavelNotifications.notify(
                title: "Gavel",
                body: "⚠️ Secret detected — \(pattern.label)\n\nSession: \(sessionTag)\n\nReview the conversation transcript before continuing.",
                critical: true
            )
            return
        }
    }
}
