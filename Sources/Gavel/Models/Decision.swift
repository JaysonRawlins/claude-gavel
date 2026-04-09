import Foundation

/// The outcome of running a PreToolUse event through the approval engine.
enum DecisionVerdict: String, Codable {
    case allow
    case block
}

/// A decision returned to the hook shim via the Unix socket.
///
/// The gavel-hook binary parses this JSON and translates to Claude Code's
/// expected format:
///   - allow → stdout with hookSpecificOutput, exit 0
///   - block → stderr "reason", exit 2
struct Decision: Codable {
    let verdict: DecisionVerdict
    let reason: String?
    let additionalContext: String?
    let updatedInput: [String: AnyCodable]?

    init(verdict: DecisionVerdict, reason: String?, additionalContext: String? = nil, updatedInput: [String: AnyCodable]? = nil) {
        self.verdict = verdict
        self.reason = reason
        self.additionalContext = additionalContext
        self.updatedInput = updatedInput
    }

    /// Internal protocol JSON sent to the gavel-hook shim via socket.
    var hookResponse: String {
        switch verdict {
        case .allow:
            // Build JSON with optional fields
            var obj: [String: Any] = ["verdict": "allow"]
            if let ctx = additionalContext, !ctx.isEmpty {
                obj["additionalContext"] = ctx
            }
            if let input = updatedInput {
                var dict: [String: Any] = [:]
                for (k, v) in input {
                    if let s = v.stringValue { dict[k] = s }
                    else if let i = v.intValue { dict[k] = i }
                    else if let b = v.boolValue { dict[k] = b }
                }
                obj["updatedInput"] = dict
            }
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return #"{"verdict":"allow"}"#
        case .block:
            let r = reason ?? "Blocked by Gavel"
            let escaped = r.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"verdict":"block","reason":"\#(escaped)"}"#
        }
    }
}

/// A record of a decision for the activity feed.
struct DecisionRecord {
    let timestamp: Date
    let sessionPid: Int
    let toolName: String
    let summary: String
    let decision: Decision
    let badge: DecisionBadge
}

enum DecisionBadge: String {
    case allow = "ALLOW"
    case autoApprove = "AUTO"
    case sandbox = "SANDBOX"
    case block = "BLOCK"
    case paused = "PAUSED"
}
