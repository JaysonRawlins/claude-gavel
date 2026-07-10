import Foundation

/// Persistent rule storage for approval decisions.
///
/// Rules are loaded from a JSON config file and can be modified
/// at runtime via the approval panel ("Always Deny" / "Always Allow").
/// Deny rules take absolute priority — they block even under auto-approve.
///
/// On first load, default MCP exfiltration rules are seeded into rules.json
/// so they're visible, searchable, and editable in the Rules tab.
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [PersistentRule] = []
    private var deletedBuiltInPatterns: [String] = []
    private var fileVersion: Int = 0
    private let configPath: String

    enum IntegrityStatus { case intact, established, restoredFromBackup, resetToDefaults }
    private(set) var lastLoadIntegrityStatus: IntegrityStatus = .intact

    private var signaturePath: String { configPath + ".integrity" }
    private var backupPath: String { configPath + ".bak" }

    /// Tamper-evident journal of every authorized rule mutation. Sibling of
    /// rules.json (rules.audit.jsonl). Nil for /dev/* config paths (tests).
    private(set) lazy var auditLog: RuleAuditLog? = {
        guard !configPath.hasPrefix("/dev/") else { return nil }
        return RuleAuditLog(path: (configPath as NSString).deletingPathExtension + ".audit.jsonl")
    }()
    private lazy var baseline = ConfigBaseline(
        keyPath: (configPath as NSString).deletingLastPathComponent + "/.integrity-key"
    )

    /// Current seed version — bump when adding new default rules.
    private static let seedVersion = 14

    /// Built-in patterns replaced by a corrected/broadened seeded rule. On re-seed
    /// these are dropped from existing rules.json so a pattern fix swaps cleanly
    /// instead of leaving the old (narrower) rule behind as a duplicate.
    private static let supersededBuiltInPatterns: Set<String> = [
        "\\bgit\\s+commit\\b",  // broadened to catch `git -C <path> commit` etc.
        "\\.claude/(gavel/|settings|hooks/)",  // trailing-slash form missed `-v ~/.claude/gavel:/dst` (colon)
        "\\.claude/(gavel|settings|hooks)\\b|\\.codex/(config|hooks)\\b",  // broadened to cover .mcp.json
        "\\.claude/(gavel/|settings|hooks/)|\\.codex/(config|hooks)|\\.(zshrc|bashrc|bash_profile|profile)\\b",  // apply_patch: + .mcp.json
        "\\bgit\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+commit\\b",  // re-seed commit checkpoint as nonSuppressible
        "git\\s+push\\b.*\\b(main|master)\\b"  // replaced by any-branch nonSuppressible push checkpoint
    ]

    init(configPath: String? = nil) {
        self.configPath = configPath ?? Self.defaultConfigPath
        loadRules()
    }

    static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/gavel/rules.json"
    }

    // MARK: - Evaluation (split by verdict for priority ordering)

    func evaluateDeny(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .block && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath, toolInput: payload.toolInput) {
                var reason = "Always deny: \(rules[i].name)"
                if let explanation = rules[i].explanation, !explanation.isEmpty {
                    reason += " — \(explanation)"
                }
                return Decision(verdict: .block, reason: reason)
            }
        }
        return nil
    }

    func evaluateAllow(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .allow && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath, toolInput: payload.toolInput) {
                return Decision(verdict: .allow, reason: "Always allow: \(rules[i].name)")
            }
        }
        return nil
    }

    /// User-created prompt rules — high priority, checked before allow rules.
    func evaluateUserPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && !rules[i].builtIn && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath, toolInput: payload.toolInput) {
                return Decision(verdict: .block, reason: "Always prompt: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    /// Overridable built-in prompt rules (MCP exfil defaults, infra-apply, scheduler), checked after allow rules so a user allow rule can override.
    func evaluateBuiltInPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn && rules[i].overridable && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath, toolInput: payload.toolInput) {
                return Decision(verdict: .block, reason: "Default rule: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    /// Non-overridable built-in prompt rules (hard checkpoints like git commit) —
    /// checked BEFORE allow rules so a broad allow rule can't silence the checkpoint.
    func evaluateBuiltInPromptNonOverridable(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn && !rules[i].overridable && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath, toolInput: payload.toolInput) {
                return Decision(verdict: .block, reason: "Checkpoint: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id, nonSuppressible: rules[i].nonSuppressible)
            }
        }
        return nil
    }

    func rule(for id: UUID) -> PersistentRule? {
        rules.first { $0.id == id }
    }

    /// Toggle a rule's disabled state. Persists immediately so the change
    /// survives a daemon restart (and stays visible in the UI as "off").
    func setDisabled(id: UUID, isDisabled: Bool, origin: String = "panel") {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isDisabled = isDisabled
        saveRules()
        audit(action: isDisabled ? "rule_disabled" : "rule_enabled", origin: origin, rule: rules[idx])
    }

    // MARK: - Rule Management

    func addRule(_ rule: PersistentRule, origin: String = "panel") {
        rules.append(rule)
        saveRules()
        audit(action: "rule_added", origin: origin, rule: rule)
    }

    func removeRule(id: UUID, origin: String = "panel") {
        guard let rule = rules.first(where: { $0.id == id }) else { return }
        if rule.builtIn {
            deletedBuiltInPatterns.append(rule.pattern)
        }
        rules.removeAll { $0.id == id }
        saveRules()
        audit(action: "rule_removed", origin: origin, rule: rule)
    }

    func updateRule(id: UUID, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String?, argConditions: [String: String]? = nil, origin: String = "panel") {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        let old = rules[idx]
        rules[idx] = PersistentRule(
            replacing: old, pattern: pattern, isRegex: isRegex,
            verdict: verdict, explanation: explanation, argConditions: argConditions
        )
        saveRules()
        audit(action: "rule_updated", origin: origin, rule: rules[idx],
              detail: old.pattern == pattern ? nil : "was: \(old.pattern)")
    }

    private func audit(action: String, origin: String, rule: PersistentRule, detail: String? = nil) {
        // Arg-scoped rules record their conditions so the journal shows the
        // narrowed form, not what looks like a blanket allow.
        var detail = detail
        if let conditions = rule.argConditions, !conditions.isEmpty {
            let scope = conditions.sorted { $0.key < $1.key }
                .map { "\($0.key)=/\($0.value)/" }.joined(separator: ", ")
            detail = [detail, "args: \(scope)"].compactMap { $0 }.joined(separator: " · ")
        }
        auditLog?.record(
            action: action, origin: origin,
            toolName: rule.toolName, pattern: rule.pattern,
            verdict: rule.verdict.rawValue, detail: detail
        )
    }

    var denyRules: [PersistentRule] {
        rules.filter { $0.verdict == .block }
    }

    var allowRules: [PersistentRule] {
        rules.filter { $0.verdict == .allow }
    }

    // MARK: - Seeded Defaults

    /// Default prompt rules seeded into rules.json — visible, searchable, editable.
    /// Two categories: MCP exfiltration vectors and Gavel self-protection.
    static let seededDefaults: [PersistentRule] = [
        // ── MCP exfiltration vectors ──
        PersistentRule(
            toolName: "*",
            pattern: "mcp__.*[Ss]lack.*(send|update|delete|upload)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Slack can send data to external channels",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "mcp__.*[Pp]laywright.*(navigate$|evaluate|type|fill|click|run_code)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Browser can navigate to attacker URLs with data in params",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "mcp__.*mail.*(send|create|draft)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Email can send data to arbitrary recipients",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "mcp__.*webhook.*(send|create|trigger)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Webhooks can send data to arbitrary endpoints",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "mcp__.*http.*(post|put|patch|delete)",
            isRegex: true,
            verdict: .prompt,
            explanation: "HTTP writes can send data to arbitrary endpoints",
            builtIn: true
        ),

        // ── Gavel/Claude self-protection: any Bash command referencing config paths ──
        // The path segment is followed by `\b` (not a literal `/`) so the directory
        // also matches when it precedes a `:` — the form a container `-v src:dst`
        // bind-mount produces (`-v ~/.claude/gavel:/dst`), which the older
        // trailing-slash pattern silently missed.
        PersistentRule(
            toolName: "Bash",
            pattern: "\\.claude/(gavel|settings|hooks)\\b|\\.codex/(config|hooks)\\b|\\.mcp\\.json\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Bash command references Gavel/Claude/Codex config or .mcp.json — session allow for legitimate use",
            builtIn: true
        ),

        // ── ANTHROPIC_BASE_URL: redirects all Claude API traffic ──
        // Setting it (export, inline env prefix, or written into a config file)
        // can route requests — and the API key — to an attacker endpoint.
        PersistentRule(
            toolName: "Bash",
            pattern: "ANTHROPIC_BASE_URL\\s*=",
            isRegex: true,
            verdict: .prompt,
            explanation: "Sets ANTHROPIC_BASE_URL — could redirect Claude API traffic and key to an attacker",
            builtIn: true
        ),

        // ── Container-runtime bind-mount of a config dir ──
        // A container started by Claude can run as root-in-container and bind-mount
        // host paths writable; the actual write happens inside the container, so the
        // protected path only appears as a `-v`/`--mount` source, evading the
        // path-write rules. Catches mounts of `.claude`/`.codex` even when the mount
        // is the parent dir (descended to inside the container).
        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(docker|podman|nerdctl|finch|orbctl|lima|colima|ctr|apptainer|singularity)\\b.*(-v|--volume|--mount)\\b[^\\n]*\\.(claude|codex)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Container bind-mounts a Claude/Codex config dir — bypasses path-write protection",
            builtIn: true
        ),

        // ── Container-runtime bind-mount of home root or filesystem root ──
        // Mounting the whole home dir (or `/`) reaches every protected path with no
        // literal `.claude` token in the command, so the rule above can't see it.
        // Project-subdir mounts (`-v ~/proj:/app`, `-v $(pwd):/app`) are unaffected.
        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(docker|podman|nerdctl|finch|orbctl|lima|colima|ctr|apptainer|singularity)\\b.*(-v|--volume)\\s*=?\\s*(~|\\$HOME|/Users/[^:/\\s]+|/)\\s*:",
            isRegex: true,
            verdict: .prompt,
            explanation: "Container bind-mounts home or filesystem root — reaches every protected path",
            builtIn: true
        ),

        // ── Codex apply_patch self-protection ──
        PersistentRule(
            toolName: "apply_patch",
            pattern: "\\.claude/(gavel/|settings|hooks/)|\\.codex/(config|hooks)|\\.mcp\\.json\\b|\\.(zshrc|bashrc|bash_profile|profile)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "apply_patch references Gavel/Claude/Codex config, .mcp.json, or shell init — verify intent",
            builtIn: true
        ),

        // ── Scripting language code execution ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(python3?|ruby|perl|node|php|lua)\\b\\s+(-[ce]|--eval)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Inline script execution — can bypass pattern matching via string construction",
            builtIn: true
        ),

        // ── AppleScript / open command (sandbox escape) ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bosascript\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "AppleScript can execute commands in other apps, bypassing Gavel entirely",
            builtIn: true
        ),
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bopen\\s+-a\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Opening apps can provide unmonitored shell access outside Gavel",
            builtIn: true
        ),

        // ── Local file read via curl (config exfil) ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bcurl\\b.*\\bfile://",
            isRegex: true,
            verdict: .prompt,
            explanation: "curl file:// reads local files — bypasses Read tool protections",
            builtIn: true
        ),

        // ── Git safety: destructive reset (discards uncommitted work) ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\s+(reset\\s+--hard|checkout\\s+--\\s+\\.|clean\\s+-[fd]|restore\\s+--staged\\s+\\.)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Destructive git operation — discards uncommitted work",
            builtIn: true
        ),

        // ── Outbound git: push / remote repoint — Allow-once only (the publish/exfil moment) ──
        // Any-branch push, not just main: pushing a feature branch still sends code off-machine.
        // Same git-global-option tolerance as the commit pattern so `git -C /repo push` can't slip past.
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+push\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Push checkpoint — code leaves the machine; review before publishing",
            builtIn: true,
            overridable: false,
            nonSuppressible: true
        ),
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+remote\\s+(add|set-url)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Git remote repoint — changes where pushes go",
            builtIn: true,
            overridable: false,
            nonSuppressible: true
        ),

        // ── Supply-chain publish: outbound artifact — Allow-once only ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(npm\\s+publish|yarn\\s+publish|pnpm\\s+publish|twine\\s+upload|cargo\\s+publish|docker\\s+push|gh\\s+release\\s+create|gh\\s+gist\\s+create)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Publish/upload — outbound artifact (supply chain)",
            builtIn: true,
            overridable: false,
            nonSuppressible: true
        ),

        // ── Commit checkpoint — Allow-once only (identity-attributing; can't be session-allowed) ──
        // Tolerates git global options before the subcommand (`-C <path>`, `-c k=v`,
        // `--no-pager`) so `git -C /repo commit` can't slip past the bare-form pattern.
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+commit\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Commit checkpoint — review staged changes before recording history",
            builtIn: true,
            overridable: false,
            nonSuppressible: true
        ),

        // ── Bash writes to guardrail paths — Allow-once only ──
        // Closes the shell bypass of the Write-tool path rules: a write verb (redirect, tee, cp,
        // mv, dd, install, sed -i) targeting a guardrail/config path. Keyed on the path literal,
        // so side-effect writers that don't name it (granted/assume, `aws configure`) stay exempt.
        // [^|;&] keeps the verb and the path within the same command segment, not across a pipe/&&.
        PersistentRule(
            toolName: "Bash",
            pattern: "(>>?|\\btee\\b|\\bcp\\b|\\bmv\\b|\\bdd\\b|\\binstall\\b|\\bsed\\s+-i\\S*)\\s*[^|;&]*(\\.claude/gavel/|\\.claude/(settings\\.json|settings\\.local\\.json|hooks/)|\\.mcp\\.json|\\.git/hooks/|\\.github/workflows/|\\.aws/config)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Writing a guardrail/config file via shell — review (Allow-once only)",
            builtIn: true,
            overridable: false,
            nonSuppressible: true
        ),

        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(cdk\\s+(deploy|destroy)|terraform\\s+(apply|destroy)|sam\\s+deploy|pulumi\\s+up|kubectl\\s+(apply|delete)|aws\\s+cloudformation\\s+deploy)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Infrastructure apply/destroy — review the changeset/plan before mutating real resources",
            builtIn: true
        ),

        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(kubectl|kubectl\\.\\S+|k)\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+(rollout|delete|apply|scale|patch|drain|cordon|uncordon|edit|replace|annotate|label|set|create|taint|rollback)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Mutating kubectl verb against a live cluster — review the target before changing cluster state",
            builtIn: true
        ),

        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(kubectl|kubectl\\.\\S+|k)\\b(?=[^&|;]*\\b(rollout|delete|apply|scale|patch|drain|cordon|uncordon|edit|replace|annotate|label|set|create|taint|rollback)\\b)(?=[^&|;]*(--(context|cluster)(=|\\s+)\\S*prod|\\b[a-z0-9]+-prod\\b|\\bprod-[a-z0-9-]+\\b))",
            isRegex: true,
            verdict: .prompt,
            explanation: "Mutating kubectl against a PROD context — prod cluster mutations must never auto-pass",
            builtIn: true,
            overridable: false
        ),

        // ── Persistence-creating scheduler tools ──
        // These plant future execution that fires while the user may not be watching.
        // Prompt even under auto-approve so the user sees and confirms each one.
        // Using toolName="*" with an anchored regex pattern gives each rule a
        // unique pattern string — needed because seed-migration dedupes on pattern.
        PersistentRule(
            toolName: "*",
            pattern: "^CronCreate$",
            isRegex: true,
            verdict: .prompt,
            explanation: "Scheduling a future prompt — plants delayed execution that runs autonomously",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "^ScheduleWakeup$",
            isRegex: true,
            verdict: .prompt,
            explanation: "Scheduling session re-entry — Claude will resume with this prompt at the given delay",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "^CronDelete$",
            isRegex: true,
            verdict: .prompt,
            explanation: "Deleting a scheduled job — could remove legitimate user-created schedules",
            builtIn: true
        ),
    ]

    // MARK: - Persistence

    private func loadRules() {
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            seedDefaults(existingRules: [], version: 0, deleted: [])
            return
        }

        // Try new envelope format first, fall back to bare array (migration)
        if let file = try? JSONDecoder().decode(RulesFile.self, from: data) {
            rules = file.rules
            fileVersion = file.version
            deletedBuiltInPatterns = file.deletedBuiltInPatterns
        } else if let bare = try? JSONDecoder().decode([PersistentRule].self, from: data) {
            rules = bare
            fileVersion = 0
            deletedBuiltInPatterns = []
        }

        let needsPersist = validateOrRecover()

        if fileVersion < Self.seedVersion {
            seedDefaults(existingRules: rules, version: fileVersion, deleted: deletedBuiltInPatterns)
        } else if needsPersist || !baseline.signatureExists(at: signaturePath) || !FileManager.default.fileExists(atPath: backupPath) {
            saveRules()
        }
    }

    private func seedDefaults(existingRules: [PersistentRule], version: Int, deleted: [String]) {
        var seeded = existingRules.filter { !($0.builtIn && Self.supersededBuiltInPatterns.contains($0.pattern)) }
        let existingPatterns = Set(seeded.map(\.pattern))
        let deletedSet = Set(deleted)

        for rule in Self.seededDefaults {
            guard !existingPatterns.contains(rule.pattern),
                  !deletedSet.contains(rule.pattern) else { continue }
            seeded.append(rule)
        }

        rules = seeded
        fileVersion = Self.seedVersion
        deletedBuiltInPatterns = deleted
        saveRules()
    }

    var filePath: String { configPath }

    func onDiskMatchesMemory() -> Bool {
        guard let raw = FileManager.default.contents(atPath: configPath),
              let onDisk = try? JSONDecoder().decode(RulesFile.self, from: raw),
              let a = canonical(onDisk), let b = canonicalRules() else { return false }
        return a == b
    }

    func reassertOnDisk() {
        saveRules()
    }

    func canonicalRules() -> Data? {
        canonical(currentRulesFile())
    }

    private func currentRulesFile() -> RulesFile {
        RulesFile(version: fileVersion, deletedBuiltInPatterns: deletedBuiltInPatterns, rules: rules)
    }

    private func canonical(_ file: RulesFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(file)
    }

    private func encodedRules() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try? encoder.encode(currentRulesFile())
    }

    private func validateOrRecover() -> Bool {
        guard baseline.signatureExists(at: signaturePath) else {
            lastLoadIntegrityStatus = .established
            return true
        }
        if let canon = canonicalRules(), baseline.isValid(canon, against: signaturePath) {
            lastLoadIntegrityStatus = .intact
            return false
        }
        if let recovered = trustedBackup() {
            rules = recovered.rules
            fileVersion = recovered.version
            deletedBuiltInPatterns = recovered.deletedBuiltInPatterns
            lastLoadIntegrityStatus = .restoredFromBackup
            return true
        }
        rules = []
        fileVersion = 0
        deletedBuiltInPatterns = []
        lastLoadIntegrityStatus = .resetToDefaults
        return true
    }

    private func trustedBackup() -> RulesFile? {
        guard let data = FileManager.default.contents(atPath: backupPath),
              let file = try? JSONDecoder().decode(RulesFile.self, from: data),
              let canon = canonical(file),
              baseline.isValid(canon, against: signaturePath) else { return nil }
        return file
    }

    private func saveRules() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let data = encodedRules() else { return }
        ConfigIntegrity.shared.withWriteWindow(path: configPath) {
            FileManager.default.createFile(atPath: configPath, contents: data)
        }
        try? data.write(to: URL(fileURLWithPath: backupPath))
        if let canon = canonicalRules() {
            baseline.recordSignature(of: canon, to: signaturePath)
        }
    }
}

// MARK: - Rules File Envelope

/// Versioned envelope for rules.json — wraps rules with metadata for seeding.
struct RulesFile: Codable {
    var version: Int
    var deletedBuiltInPatterns: [String]
    var rules: [PersistentRule]
}

// MARK: - Persistent Rule

/// A persistent approval rule saved to rules.json.
///
/// Supports two pattern modes:
/// - **Glob** (default): `*` matches any characters. E.g. `swift build*`
/// - **Regex**: Full regex with lookaheads etc. Toggle Regex in the UI.
struct PersistentRule: Codable, Identifiable {
    let id: UUID
    let name: String
    let toolName: String
    let pattern: String
    let isRegex: Bool
    let verdict: DecisionVerdict
    let createdAt: Date
    /// Explanation shown to Claude when a deny rule fires (e.g. "use --only-names flag instead").
    let explanation: String?
    /// True for seeded default rules (MCP exfil patterns). User rules are always false.
    let builtIn: Bool
    /// When true (default), a user allow rule can override this built-in prompt; false marks a hard checkpoint (e.g. git commit) that allow rules can't silence.
    let overridable: Bool
    /// When true, this checkpoint is Allow-once only: the router won't let a session-allow or
    /// suppressed-rule short-circuit it, and the coordinator refuses session/persistent allow on it.
    /// Hard-coded on built-in rules guarding irreversible/outbound actions (commit, push, publish).
    let nonSuppressible: Bool
    /// Skip this rule during evaluation when true. Persisted so the disable
    /// survives daemon restarts (so a forgotten "temporarily off" rule still
    /// surfaces in the UI rather than silently re-engaging on reboot). Toggle
    /// from the Rules tab; defaults to false (rule active).
    var isDisabled: Bool
    /// Per-argument conditions (arg name → regex) narrowing when this rule fires,
    /// e.g. scoping an MCP allow to `channel` values in an allowlist. Each regex is
    /// full-string anchored at match time and EVERY condition must match; an absent
    /// arg fails closed. Allow rules only — on a deny/prompt rule conditions would
    /// narrow the guard (a loosening), so both inits and the decoder drop them
    /// unless verdict == .allow. Tighten-only: conditions can only shrink an allow.
    let argConditions: [String: String]?

    /// Pre-compiled regex (rebuilt on first access, not persisted).
    private var _compiledRegex: NSRegularExpression?
    /// Pre-compiled anchored arg-condition regexes (rebuilt on first use, not persisted).
    private var _compiledArgRegexes: [String: NSRegularExpression] = [:]
    var compiledRegex: NSRegularExpression? {
        mutating get {
            if _compiledRegex == nil {
                _compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
            }
            return _compiledRegex
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, toolName, pattern, isRegex, verdict, createdAt, explanation, builtIn, overridable, isDisabled, nonSuppressible, argConditions
    }

    /// Backward-compatible decoding — isRegex, explanation, builtIn, isDisabled,
    /// nonSuppressible all default for old rules.json files lacking the field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        toolName = try c.decode(String.self, forKey: .toolName)
        pattern = try c.decode(String.self, forKey: .pattern)
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        verdict = try c.decode(DecisionVerdict.self, forKey: .verdict)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        overridable = try c.decodeIfPresent(Bool.self, forKey: .overridable) ?? true
        isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        nonSuppressible = try c.decodeIfPresent(Bool.self, forKey: .nonSuppressible) ?? false
        argConditions = Self.sanitizedConditions(
            try c.decodeIfPresent([String: String].self, forKey: .argConditions), verdict: verdict)
    }

    init(
        toolName: String,
        pattern: String,
        isRegex: Bool = false,
        verdict: DecisionVerdict,
        explanation: String? = nil,
        builtIn: Bool = false,
        overridable: Bool = true,
        isDisabled: Bool = false,
        nonSuppressible: Bool = false,
        argConditions: [String: String]? = nil
    ) {
        self.id = UUID()
        self.toolName = toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.createdAt = Date()
        self.argConditions = Self.sanitizedConditions(argConditions, verdict: verdict)
        self.name = "\(toolName): \(isRegex ? "/" : "")\(pattern)\(isRegex ? "/" : "")"
            + Self.conditionsSuffix(self.argConditions)
        self.explanation = explanation
        self.builtIn = builtIn
        self.overridable = overridable
        self.isDisabled = isDisabled
        self.nonSuppressible = nonSuppressible
        self._compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
    }

    /// Update a rule's editable fields while preserving identity (id, toolName, createdAt, builtIn).
    init(replacing old: PersistentRule, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String?, argConditions: [String: String]? = nil) {
        self.id = old.id
        self.toolName = old.toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.createdAt = old.createdAt
        self.argConditions = Self.sanitizedConditions(argConditions, verdict: verdict)
        self.name = "\(old.toolName): \(isRegex ? "/" : "")\(pattern)\(isRegex ? "/" : "")"
            + Self.conditionsSuffix(self.argConditions)
        self.explanation = explanation
        self.builtIn = old.builtIn
        self.overridable = old.overridable
        self.isDisabled = old.isDisabled
        self.nonSuppressible = old.nonSuppressible
        self._compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
    }

    /// Drop conditions on non-allow verdicts (they'd narrow a deny/prompt — a
    /// loosening) and strip blank keys/patterns; empty result collapses to nil.
    private static func sanitizedConditions(_ conditions: [String: String]?, verdict: DecisionVerdict) -> [String: String]? {
        guard verdict == .allow, let conditions else { return nil }
        let cleaned = conditions.filter {
            !$0.key.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func conditionsSuffix(_ conditions: [String: String]?) -> String {
        guard let conditions, !conditions.isEmpty else { return "" }
        let parts = conditions.sorted { $0.key < $1.key }.map { "\($0.key)=/\($0.value)/" }
        return " [\(parts.joined(separator: ", "))]"
    }

    mutating func matches(toolName: String, command: String?, filePath: String?, toolInput: [String: AnyCodable]? = nil) -> Bool {
        guard self.toolName == toolName || self.toolName == "*" else { return false }
        guard argConditionsSatisfied(by: toolInput) else { return false }

        let raw: String
        switch toolName {
        case "Bash":
            raw = PatternMatcher.joinLineContinuations(command ?? "")
        case "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep":
            raw = filePath ?? command ?? ""
        default:
            raw = command ?? filePath ?? ""
        }

        let target = Self.sanitizeDashes(raw)

        guard let regex = compiledRegex else { return false }

        // Match against command/filePath
        if matchesRegex(regex, in: target) {
            // For Bash: verify it's not a false positive inside a heredoc or quoted string
            if toolName == "Bash" {
                let stripped = PatternMatcher.stripQuotedContent(target)
                if !matchesRegex(regex, in: stripped) { /* false positive */ }
                else { return true }
            } else {
                return true
            }
        }

        // For Bash: expand inline variables and re-check.
        // Catches: D="doppler"; $D secrets → doppler secrets
        if toolName == "Bash" && !raw.isEmpty {
            let expanded = PatternMatcher.expandInlineVariables(raw)
            if expanded != raw {
                let expandedTarget = Self.sanitizeDashes(expanded)
                let strippedExpanded = PatternMatcher.stripQuotedContent(expandedTarget)
                if matchesRegex(regex, in: strippedExpanded) {
                    return true
                }
            }
        }

        // Per-segment match: a negative lookahead (e.g. (?!.*--only-names)) on the
        // whole compound command is suppressed by a safe token in a LATER segment.
        if toolName == "Bash" && (verdict == .block || verdict == .prompt) {
            if matchesAnySegment(regex, in: target) { return true }
            if !raw.isEmpty {
                let expanded = PatternMatcher.expandInlineVariables(raw)
                if expanded != raw, matchesAnySegment(regex, in: Self.sanitizeDashes(expanded)) {
                    return true
                }
            }
        }

        // For wildcard rules, also match against the tool name itself.
        // MCP tools carry their identity in the name (e.g. mcp__LinkedIn__linkedin_create_post)
        // and typically have no command or filePath.
        if self.toolName == "*" {
            return regex.firstMatch(in: toolName, range: NSRange(toolName.startIndex..., in: toolName)) != nil
        }

        return false
    }

    private func matchesRegex(_ regex: NSRegularExpression, in string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// Every condition's regex must fully match the stringified arg value.
    /// Fail closed: absent arg, non-scalar value, or an uncompilable pattern
    /// all reject — the rule simply doesn't fire and evaluation falls through.
    private mutating func argConditionsSatisfied(by toolInput: [String: AnyCodable]?) -> Bool {
        guard let conditions = argConditions, !conditions.isEmpty else { return true }
        for (arg, pattern) in conditions {
            guard let value = toolInput?[arg].flatMap(Self.scalarString),
                  let regex = compiledArgRegex(arg: arg, pattern: pattern),
                  matchesRegex(regex, in: value) else { return false }
        }
        return true
    }

    /// Stringify scalar arg values so conditions can also pin ints/bools
    /// (e.g. `limit=/50/`). Dicts, arrays, and null stay nil → fail closed.
    /// Also used by the approval panel to decide which args are scopable.
    static func scalarString(_ value: AnyCodable) -> String? {
        switch value.value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        default: return nil
        }
    }

    /// Anchored `\A(?:pattern)\z` so a condition can't substring-match
    /// (`C123` must not pass `C1234`) — strictly narrower, tighten-only.
    private mutating func compiledArgRegex(arg: String, pattern: String) -> NSRegularExpression? {
        if let cached = _compiledArgRegexes[arg] { return cached }
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") else { return nil }
        _compiledArgRegexes[arg] = regex
        return regex
    }

    private func matchesAnySegment(_ regex: NSRegularExpression, in command: String) -> Bool {
        for segment in SessionRule.splitCommandSegments(command) {
            let stripped = PatternMatcher.stripQuotedContent(segment)
            if matchesRegex(regex, in: segment) && matchesRegex(regex, in: stripped) {
                return true
            }
        }
        return false
    }

    private static func sanitizeDashes(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2012}", with: "-")
    }

    /// Compile a pattern to regex. Glob patterns are converted; regex patterns used as-is.
    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        PatternCompiler.compilePattern(pattern, isRegex: isRegex)
    }

    /// Test a pattern against a sample string. Returns match result and any regex error.
    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        PatternCompiler.testPattern(pattern, isRegex: isRegex, against: sample)
    }
}
