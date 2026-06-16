import Foundation

/// Shared credential regex set used by `SecretHandler` and `CredentialGate`.
/// Provides recognized-secret detection and labeled-placeholder redaction.
enum SecretRedactor {

    struct Pattern {
        let label: String
        let regex: NSRegularExpression
    }

    static let patterns: [Pattern] = {
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
        return raw.compactMap { label, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Pattern(label: label, regex: regex)
        }
    }()

    static func firstMatchLabel(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns where pattern.regex.firstMatch(in: text, range: range) != nil {
            return pattern.label
        }
        return nil
    }

    static func containsKnownSecret(_ text: String) -> Bool {
        firstMatchLabel(in: text) != nil
    }

    static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "‹\(pattern.label) redacted›"
            )
        }
        return result
    }
}
