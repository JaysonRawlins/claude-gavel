import Foundation

/// Core approval logic. Evaluates a PreToolUse event against a strict priority chain:
///
/// 1. Hard-blocked dangerous patterns (always block, not overridable)
/// 2. Persistent DENY rules from RuleStore (block even under auto-approve)
/// 3. Session pause state
/// 4. Persistent ALLOW rules from RuleStore
/// 5. Timed auto-approve
/// 6. Default: pass through to interactive approval
///
/// Key invariant: deny rules ALWAYS win over auto-approve.
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

        // 4. Persistent ALLOW rules
        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        // 5. MCP tool blocking (after allow rules, so users can override)
        // Returns .block but with askUser flag — router shows dialog instead of hard block
        if let reason = patternMatcher.matchMcpDangerous(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        // 6. Timed auto-approve
        if session.isAutoApproveActive {
            return Decision(verdict: .allow, reason: "AUTO-APPROVED (timed)")
        }

        // 7. Default: pass through (HookRouter decides: auto-approve, session rules, or dialog)
        return Decision(verdict: .allow, reason: nil)
    }
}
