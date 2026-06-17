import Foundation

/// Non-disableable safety gate for outbound remote-approval messages.
/// When any payload field is credential-shaped, the message is suppressed entirely.
enum CredentialGate {

    /// True when the payload must NOT be sent to a remote channel (Telegram).
    /// Scans every tool-input value, the command, and file path — biased to over-suppress.
    static func blocksRemote(_ payload: PreToolUsePayload) -> Bool {
        for text in scannableStrings(payload) {
            if SecretRedactor.containsKnownSecret(text) { return true }
            if containsHighEntropyRun(text) { return true }
        }
        return false
    }

    private static func scannableStrings(_ payload: PreToolUsePayload) -> [String] {
        var out: [String] = []
        collect(payload.toolInput, into: &out)
        return out
    }

    private static func collect(_ value: [String: AnyCodable], into out: inout [String]) {
        for (_, v) in value { collect(v.value, into: &out) }
    }

    private static func collect(_ value: Any, into out: inout [String]) {
        switch value {
        case let s as String:
            out.append(s)
        case let dict as [String: AnyCodable]:
            collect(dict, into: &out)
        case let arr as [AnyCodable]:
            for element in arr { collect(element.value, into: &out) }
        case let dict as [String: Any]:
            for v in dict.values { collect(v, into: &out) }
        case let arr as [Any]:
            for element in arr { collect(element, into: &out) }
        default:
            break
        }
    }

    /// A 20+ char key-like run that is not a UUID or ISO-8601 timestamp is
    /// credential-shaped. `/` is excluded so paths split into short segments.
    static func containsHighEntropyRun(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let matches = entropyRegex.matches(in: text, range: range)
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            let token = String(text[r])
            if isWhitelisted(token) { continue }
            return true
        }
        return false
    }

    private static func isWhitelisted(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        if uuidRegex.firstMatch(in: token, range: range) != nil { return true }
        if iso8601Regex.firstMatch(in: token, range: range) != nil { return true }
        if identifierRegex.firstMatch(in: token, range: range) != nil { return true }
        return false
    }

    private static let entropyRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9_+\\-]{\(GavelConstants.credentialEntropyRunLength),}"
    )

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    private static let iso8601Regex = try! NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}([T ]\\d{2}:\\d{2}(:\\d{2})?)?"
    )

    private static let identifierRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9]+([_-][A-Za-z0-9]+)+$"
    )
}
