import Foundation

/// Strict priority chain: dangerous → deny → pause → user-prompt → sensitive-path → allow → builtin-prompt → auto → pass-through. Deny always beats auto; sensitive-paths always force a dialog.
final class ApprovalEngine {
    let patternMatcher: PatternMatcher
    let ruleStore: RuleStore

    init(patternMatcher: PatternMatcher = PatternMatcher(), ruleStore: RuleStore = RuleStore()) {
        self.patternMatcher = patternMatcher
        self.ruleStore = ruleStore
    }

    func evaluate(payload: PreToolUsePayload, session: Session) -> Decision {
        // 1. Hard-coded dangerous patterns — non-overridable.
        if let reason = patternMatcher.matchDangerous(payload: payload) {
            return Decision(verdict: .block, reason: reason)
        }

        // 2. Persistent DENY rules — block even under auto-approve.
        if let decision = ruleStore.evaluateDeny(payload: payload) {
            return decision
        }

        // 3. Session pause.
        if session.isPaused {
            return Decision(verdict: .block, reason: "Session paused via Gavel")
        }

        // 4. User PROMPT rules — force dialog, beats allow rules below.
        if let decision = ruleStore.evaluateUserPrompt(payload: payload) {
            return decision
        }

        // 5. Sensitive paths — checked BEFORE allow rules so a broad `Read: *` can't bypass self-protection.
        if let reason = patternMatcher.matchSensitivePath(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        // 6. Persistent ALLOW rules.
        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        // 7. Built-in PROMPT rules — overridable by Stage 6 allow rules above.
        if let decision = ruleStore.evaluateBuiltInPrompt(payload: payload) {
            return decision
        }

        // 8. Timed auto-approve.
        if session.isAutoApproveActive {
            return Decision(verdict: .allow, reason: "AUTO-APPROVED (timed)")
        }

        // 9. Pass-through — HookRouter applies auto-approve, session rules, or dialog.
        return Decision(verdict: .allow, reason: nil)
    }
}
