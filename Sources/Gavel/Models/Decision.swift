import Foundation

/// Approval engine outcome for a PreToolUse event.
enum DecisionVerdict: String, Codable {
    case allow
    case block
    case prompt  // Always show interactive dialog, even under auto-approve.
}

/// Wire format to the gavel-hook shim: allow → stdout+exit 0, block → stderr "reason"+exit 2.
struct Decision: Codable {
    let verdict: DecisionVerdict
    let reason: String?
    let additionalContext: String?
    let updatedInput: [String: AnyCodable]?
    /// When true, router shows a dialog instead of hard-blocking — used for MCP-tier blocks that the user should approve case-by-case.
    let askUser: Bool
    /// Set when a persistent prompt rule fired — drives per-session rule suppression.
    let triggeringRuleId: UUID?

    init(verdict: DecisionVerdict, reason: String?, additionalContext: String? = nil, updatedInput: [String: AnyCodable]? = nil, askUser: Bool = false, triggeringRuleId: UUID? = nil) {
        self.verdict = verdict
        self.reason = reason
        self.additionalContext = additionalContext
        self.updatedInput = updatedInput
        self.askUser = askUser
        self.triggeringRuleId = triggeringRuleId
    }

    /// Protocol JSON the daemon writes back to the gavel-hook subprocess via socket.
    var hookResponse: String {
        switch verdict {
        case .allow:
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
            let obj: [String: Any] = ["verdict": "block", "reason": r]
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return #"{"verdict":"block","reason":"Blocked by Gavel"}"#
        case .prompt:
            // Prompt verdicts are handled in the router (show dialog) — should never reach hookResponse, but fail-closed if we ever do.
            return #"{"verdict":"block","reason":"Requires approval"}"#
        }
    }
}

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
