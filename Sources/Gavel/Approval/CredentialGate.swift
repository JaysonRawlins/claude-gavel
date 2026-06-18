import Foundation

/// Non-disableable safety gate that withholds credential-shaped commands from the remote channel.
enum CredentialGate {

    /// What tripped the gate — carries only log-safe fragments, never the full token.
    enum Trigger: Equatable {
        case knownPattern(label: String)
        case entropyRun(prefix: String, length: Int)

        var logDescription: String {
            switch self {
            case .knownPattern(let label): return "known-pattern \"\(label)\""
            case .entropyRun(let prefix, let length): return "entropy-run prefix=\"\(prefix)…\" len=\(length)"
            }
        }
    }

    /// The first credential-shaped trigger in the payload, or nil when clean.
    static func inspect(_ payload: PreToolUsePayload) -> Trigger? {
        for text in scannableStrings(payload) {
            if let label = SecretRedactor.firstMatchLabel(in: text) {
                return .knownPattern(label: label)
            }
            if let run = firstHighEntropyRun(in: text) {
                return .entropyRun(prefix: String(run.prefix(4)), length: run.count)
            }
        }
        return nil
    }

    /// True when the payload's command must be withheld from the remote channel.
    static func blocksRemote(_ payload: PreToolUsePayload) -> Bool {
        inspect(payload) != nil
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

    /// True when the text contains a non-whitelisted 20+ char key-like run.
    static func containsHighEntropyRun(_ text: String) -> Bool {
        firstHighEntropyRun(in: text) != nil
    }

    /// The first non-whitelisted 20+ char key-like run, or nil — `/` is excluded so paths split into short segments.
    static func firstHighEntropyRun(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for match in entropyRegex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let token = String(text[r])
            if isWhitelisted(token) { continue }
            return token
        }
        return nil
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
