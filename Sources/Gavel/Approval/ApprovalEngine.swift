import Foundation

/// Evaluates a PreToolUse event in strict priority order (dangerous, deny, pause, checkpoints, sensitive paths, prompt, allow, auto-approve); deny rules and the commit/sensitive-path checkpoints always beat any allow.
final class ApprovalEngine {
    let patternMatcher: PatternMatcher
    let ruleStore: RuleStore

    init(patternMatcher: PatternMatcher = PatternMatcher(), ruleStore: RuleStore = RuleStore()) {
        self.patternMatcher = patternMatcher
        self.ruleStore = ruleStore
    }

    func evaluate(payload: PreToolUsePayload, session: Session) -> Decision {
        if let reason = patternMatcher.matchDangerous(payload: payload) {
            return Decision(verdict: .block, reason: reason)
        }

        if let decision = ruleStore.evaluateDeny(payload: payload) {
            return decision
        }

        if session.isPaused {
            return Decision(verdict: .block, reason: "Session paused via Gavel")
        }

        if let decision = ruleStore.evaluateBuiltInPromptNonOverridable(payload: payload) {
            return decision
        }

        if let reason = patternMatcher.matchSensitivePath(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        if let decision = ruleStore.evaluateUserPrompt(payload: payload) {
            return decision
        }

        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        if let decision = ruleStore.evaluateBuiltInPrompt(payload: payload) {
            return decision
        }

        if session.isAutoApproveActive {
            return Decision(verdict: .allow, reason: "AUTO-APPROVED (timed)")
        }

        return Decision(verdict: .allow, reason: nil)
    }
}
