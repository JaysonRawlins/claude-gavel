import Foundation

/// Core approval logic. Evaluates a PreToolUse event against a strict priority chain:
///
/// 1. Hard-blocked dangerous patterns (always block, not overridable)
/// 2. Persistent DENY rules from RuleStore (block even under auto-approve)
/// 3. Session pause state
/// 4. User PROMPT rules (force dialog even under auto-approve)
/// 5. Sensitive paths — gavel config, hooks, shell config (force dialog, not overridable)
/// 6. Persistent ALLOW rules from RuleStore
/// 7. Built-in PROMPT rules (seeded MCP exfil defaults, overridable by allow rules)
/// 8. Timed auto-approve
/// 9. Default: pass through to interactive approval
///
/// Key invariants:
/// - Deny rules ALWAYS win over auto-approve.
/// - Sensitive paths ALWAYS force a dialog — even with a broad allow rule like `Read: *`.
/// - Built-in prompt rules are overridable by user allow rules (Stage 6 beats Stage 7).
/// - User prompt rules are NOT overridable by allow rules (Stage 4 beats Stage 6).
final class ApprovalEngine {
    let patternMatcher: PatternMatcher
    let ruleStore: RuleStore

    init(patternMatcher: PatternMatcher = PatternMatcher(), ruleStore: RuleStore = RuleStore()) {
        self.patternMatcher = patternMatcher
        self.ruleStore = ruleStore
    }

    func evaluate(payload: PreToolUsePayload, session: Session) -> Decision {
        // 1. Hard-coded dangerous patterns (always block, no override)
        if let reason = patternMatcher.matchDangerous(payload: payload) {
            return Decision(verdict: .block, reason: reason)
        }

        // 2. Persistent DENY rules — block even under auto-approve
        if let decision = ruleStore.evaluateDeny(payload: payload) {
            return decision
        }

        // 3. Session pause state
        if session.isPaused {
            return Decision(verdict: .block, reason: "Session paused via Gavel")
        }

        // 4. User PROMPT rules (builtIn=false) — force dialog, beats allow rules
        if let decision = ruleStore.evaluateUserPrompt(payload: payload) {
            return decision
        }

        // 5. Sensitive paths — gavel config, hooks, shell config (force dialog)
        //    Checked BEFORE allow rules so broad rules like `Read: *` can't bypass self-protection.
        if let reason = patternMatcher.matchSensitivePath(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        // 6. Persistent ALLOW rules
        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        // 7. Built-in PROMPT rules (builtIn=true) — overridable by allow rules above
        if let decision = ruleStore.evaluateBuiltInPrompt(payload: payload) {
            return decision
        }

        // 8. Timed auto-approve
        if session.isAutoApproveActive {
            return Decision(verdict: .allow, reason: "AUTO-APPROVED (timed)")
        }

        // 9. Default: pass through (HookRouter decides: auto-approve, session rules, or dialog)
        return Decision(verdict: .allow, reason: nil)
    }
}
