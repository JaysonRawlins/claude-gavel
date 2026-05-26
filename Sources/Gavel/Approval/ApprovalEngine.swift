import Foundation

/// Core approval logic. Evaluates a PreToolUse event against a strict priority chain:
///
/// 1.  Hard-blocked dangerous patterns (always block, not overridable)
/// 2.  Persistent DENY rules from RuleStore (block even under auto-approve)
/// 2.5 Plan overlay prohibitions — plan-declared deny/block (force dialog / hard block)
/// 3.  Session pause state
/// 4.  User PROMPT rules (force dialog even under auto-approve)
/// 4.5 Non-overridable built-in checkpoints — e.g. git commit (force dialog, beats allow rules)
/// 5.  Sensitive paths — gavel config, hooks, shell config (force dialog, not overridable)
/// 6a. Plan overlay authorizations — plan pre-approved this command (suppresses overridable prompts)
/// 6b. Persistent ALLOW rules from RuleStore
/// 7.  Overridable built-in PROMPT rules (seeded MCP exfil / infra-apply defaults, overridable)
/// 8.  Timed auto-approve
/// 9.  Default: pass through to interactive approval
///
/// There is no "bypass everything" mode: engaging a plan layers an allow/deny
/// overlay (stages 2.5 / 6a) and turns on auto-approve for the inner loop, but
/// standing checkpoints, sensitive paths, and hard blocks always apply.
///
/// Key invariants:
/// - Deny rules ALWAYS win over auto-approve.
/// - Plan overlay prohibitions beat everything except hard blocks and persistent deny.
/// - Sensitive paths ALWAYS force a dialog — even with a broad allow rule like `Read: *`.
/// - Overridable built-in prompts are overridable by overlay/user allow (Stage 6 beats Stage 7).
/// - User prompt rules and non-overridable checkpoints are NOT overridable by allow rules
///   (Stage 4 / 4.5 beat Stage 6).
final class ApprovalEngine {
    let patternMatcher: PatternMatcher
    let ruleStore: RuleStore

    init(patternMatcher: PatternMatcher = PatternMatcher(), ruleStore: RuleStore = RuleStore()) {
        self.patternMatcher = patternMatcher
        self.ruleStore = ruleStore
    }

    func evaluate(payload: PreToolUsePayload, session: Session) -> Decision {
        let overlay = session.overlayRules

        // 1. Hard-coded dangerous patterns (always block, no override)
        if let reason = patternMatcher.matchDangerous(payload: payload) {
            return Decision(verdict: .block, reason: reason)
        }

        // 2. Persistent DENY rules — block even under auto-approve
        if let decision = ruleStore.evaluateDeny(payload: payload) {
            return decision
        }

        // 2.5 Plan overlay prohibitions — plan-declared deny/block (force dialog / hard block)
        if let decision = overlayProhibition(overlay, payload) {
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

        // 4.5 Non-overridable built-in checkpoints (e.g. git commit) — force dialog,
        //     checked before allow/overlay-allow so nothing can silence them.
        if let decision = ruleStore.evaluateBuiltInPromptNonOverridable(payload: payload) {
            return decision
        }

        // 5. Sensitive paths — gavel config, hooks, shell config (force dialog)
        //    Checked BEFORE allow rules so broad rules like `Read: *` can't bypass self-protection.
        if let reason = patternMatcher.matchSensitivePath(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        // 6a. Plan overlay authorizations — the plan pre-approved this command, so it
        //     suppresses overridable built-in prompts (e.g. infra-apply) below.
        if let decision = overlayAuthorization(overlay, payload) {
            return decision
        }

        // 6b. Persistent ALLOW rules
        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        // 7. Overridable built-in PROMPT rules — overridable by allow rules above
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

    private func overlayProhibition(_ overlay: [PlanPolicyRule], _ payload: PreToolUsePayload) -> Decision? {
        for rule in overlay where rule.verdict != .allow {
            guard rule.matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) else { continue }
            let detail = rule.explanation.map { " — \($0)" } ?? ""
            let reason = "Plan prohibits \(rule.toolName): \(rule.pattern)\(detail)"
            return Decision(verdict: .block, reason: reason, askUser: rule.verdict == .prompt)
        }
        return nil
    }

    private func overlayAuthorization(_ overlay: [PlanPolicyRule], _ payload: PreToolUsePayload) -> Decision? {
        for rule in overlay where rule.verdict == .allow {
            guard rule.matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) else { continue }
            return Decision(verdict: .allow, reason: "Plan authorizes \(rule.toolName): \(rule.pattern)")
        }
        return nil
    }
}
