import Foundation

/// Core approval logic. Evaluates a PreToolUse event against a strict priority chain:
///
/// 1.  Hard-blocked dangerous patterns (always block, not overridable)
/// 2.  Persistent DENY rules from RuleStore (block even under auto-approve)
/// 3.  Plan overlay prohibitions — plan-declared deny/block (force dialog / hard block)
/// 4.  Session pause state
/// 5.  Non-overridable built-in checkpoints — e.g. git commit (force dialog; beats every
///     allow, but a plan-declared `override` for the command releases it)
/// 6.  Sensitive paths — gavel config, hooks, shell config (force dialog, not overridable)
/// 7.  Plan overlay authorizations — plan pre-approved this command (beats user prompts + below)
/// 8.  User PROMPT rules (force dialog even under auto-approve)
/// 9.  Persistent ALLOW rules from RuleStore
/// 10. Overridable built-in PROMPT rules (seeded MCP exfil / infra-apply defaults)
/// 11. Timed auto-approve
/// 12. Default: pass through to interactive approval
///
/// There is no "bypass everything" mode: engaging a plan layers an allow/deny
/// overlay (stages 3 / 7) and turns on auto-approve for the inner loop, but
/// standing checkpoints, sensitive paths, and hard blocks always apply.
///
/// Key invariants:
/// - Deny rules ALWAYS win over auto-approve.
/// - Plan overlay prohibitions beat everything except hard blocks and persistent deny.
/// - The commit checkpoint + sensitive paths beat EVERY allow, including the overlay —
///   except a plan-declared `override`, which releases the commit checkpoint only
///   (never sensitive paths, never hard dangerous patterns).
/// - A plan overlay allow beats user PROMPT rules and below — a narrow, reviewed,
///   hash-locked authorization overrides a broad standing prompt for that command only.
/// - User prompt rules still beat persistent allow rules (Stage 8 beats Stage 9).
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

        // 4. Non-overridable built-in checkpoints (e.g. git commit) — force dialog,
        //    checked before any allow rule. The one exception: a plan that explicitly
        //    declares `override` for this command releases the checkpoint (GitOps repos
        //    where commit IS the deploy). `allow` cannot do this — only `override`.
        if let decision = ruleStore.evaluateBuiltInPromptNonOverridable(payload: payload) {
            if let release = overlayCheckpointOverride(overlay, payload) { return release }
            return decision
        }

        // 5. Sensitive paths — gavel config, hooks, shell config (force dialog)
        //    Checked before any allow so broad rules like `Read: *` can't bypass self-protection.
        if let reason = patternMatcher.matchSensitivePath(payload: payload) {
            return Decision(verdict: .block, reason: reason, askUser: true)
        }

        // 6. Plan overlay authorizations — the plan pre-approved this command. Placed
        //    above user PROMPT rules so a narrow, reviewed, hash-locked plan allow can
        //    override a broad standing prompt (e.g. authorize `cdk deploy GreenfieldStack`
        //    despite a general `cdk deploy` prompt rule). Still below deny / checkpoint /
        //    sensitive paths, so it never overrides a hard rule.
        if let decision = overlayAuthorization(overlay, payload) {
            return decision
        }

        // 7. User PROMPT rules (builtIn=false) — force dialog, beats allow rules below
        if let decision = ruleStore.evaluateUserPrompt(payload: payload) {
            return decision
        }

        // 8. Persistent ALLOW rules
        if let decision = ruleStore.evaluateAllow(payload: payload) {
            return decision
        }

        // 9. Overridable built-in PROMPT rules — overridable by allow rules above
        if let decision = ruleStore.evaluateBuiltInPrompt(payload: payload) {
            return decision
        }

        // 10. Timed auto-approve
        if session.isAutoApproveActive {
            return Decision(verdict: .allow, reason: "AUTO-APPROVED (timed)")
        }

        // 11. Default: pass through (HookRouter decides: auto-approve, session rules, or dialog)
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

    private func overlayCheckpointOverride(_ overlay: [PlanPolicyRule], _ payload: PreToolUsePayload) -> Decision? {
        for rule in overlay where rule.isCheckpointOverride {
            guard rule.matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) else { continue }
            return Decision(verdict: .allow, reason: "Plan overrides checkpoint \(rule.toolName): \(rule.pattern)")
        }
        return nil
    }
}
