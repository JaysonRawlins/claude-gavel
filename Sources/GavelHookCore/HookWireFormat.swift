import Foundation

/// Translates a Gavel allow-verdict into the stdout JSON each agent's hook contract accepts.
public enum HookWireFormat {
    /// PreToolUse allow stdout; Codex (0.142+) rejects `permissionDecision`/`updatedInput`, so allow is `hookEventName` only.
    public static func preToolUseAllow(
        isCodex: Bool,
        additionalContext: String? = nil,
        updatedInput: [String: Any]? = nil
    ) -> String {
        var output: [String: Any] = ["hookEventName": "PreToolUse"]
        if let ctx = additionalContext, !ctx.isEmpty {
            output["additionalContext"] = ctx
        }
        if !isCodex {
            output["permissionDecision"] = "allow"
            if let updated = updatedInput {
                output["updatedInput"] = updated
            }
        }
        let wrapper: [String: Any] = ["hookSpecificOutput": output]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let str = String(data: data, encoding: .utf8) else {
            return codexSafeAllow
        }
        return str
    }

    /// PermissionRequest allow stdout (Claude-only; Codex registers no PermissionRequest hook).
    public static func permissionRequestAllow() -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    }

    /// Minimal allow no agent rejects, used as the serialization fallback.
    public static let codexSafeAllow = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}"#
}
