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
    private lazy var baseline = ConfigBaseline(
        keyPath: (configPath as NSString).deletingLastPathComponent + "/.integrity-key"
    )

    /// Current seed version — bump when adding new default rules.
    private static let seedVersion = 10

    /// Built-in patterns replaced by a corrected/broadened seeded rule. On re-seed
    /// these are dropped from existing rules.json so a pattern fix swaps cleanly
    /// instead of leaving the old (narrower) rule behind as a duplicate.
    private static let supersededBuiltInPatterns: Set<String> = [
        "\\bgit\\s+commit\\b",  // broadened to catch `git -C <path> commit` etc.
        "\\.claude/(gavel/|settings|hooks/)"  // trailing-slash form missed `-v ~/.claude/gavel:/dst` (colon)
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
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
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
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .allow, reason: "Always allow: \(rules[i].name)")
            }
        }
        return nil
    }

    /// User-created prompt rules — high priority, checked before allow rules.
    func evaluateUserPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && !rules[i].builtIn && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Always prompt: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    /// Overridable built-in prompt rules (MCP exfil defaults, infra-apply, scheduler) —
    /// lower priority, checked AFTER allow rules so a user allow rule or plan overlay can override.
    func evaluateBuiltInPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn && rules[i].overridable && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Default rule: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    /// Non-overridable built-in prompt rules (hard checkpoints like git commit) —
    /// checked BEFORE allow rules so a broad allow rule can't silence the checkpoint.
    func evaluateBuiltInPromptNonOverridable(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn && !rules[i].overridable && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Checkpoint: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    func rule(for id: UUID) -> PersistentRule? {
        rules.first { $0.id == id }
    }

    /// Toggle a rule's disabled state. Persists immediately so the change
    /// survives a daemon restart (and stays visible in the UI as "off").
    func setDisabled(id: UUID, isDisabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isDisabled = isDisabled
        saveRules()
    }

    // MARK: - Rule Management

    func addRule(_ rule: PersistentRule) {
        rules.append(rule)
        saveRules()
    }

    func removeRule(id: UUID) {
        if let rule = rules.first(where: { $0.id == id }), rule.builtIn {
            deletedBuiltInPatterns.append(rule.pattern)
        }
        rules.removeAll { $0.id == id }
        saveRules()
    }

    func updateRule(id: UUID, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String?) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        let old = rules[idx]
        rules[idx] = PersistentRule(
            replacing: old, pattern: pattern, isRegex: isRegex,
            verdict: verdict, explanation: explanation
        )
        saveRules()
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
            pattern: "\\.claude/(gavel|settings|hooks)\\b|\\.codex/(config|hooks)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Bash command references Gavel/Claude/Codex config — session allow for legitimate use",
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
            pattern: "\\.claude/(gavel/|settings|hooks/)|\\.codex/(config|hooks)|\\.(zshrc|bashrc|bash_profile|profile)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "apply_patch references Gavel/Claude/Codex config or shell init — verify intent",
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

        // ── Git safety: destructive reset and push to main ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\s+(reset\\s+--hard|checkout\\s+--\\s+\\.|clean\\s+-[fd]|restore\\s+--staged\\s+\\.)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Destructive git operation — discards uncommitted work",
            builtIn: true
        ),
        PersistentRule(
            toolName: "*",
            pattern: "git\\s+push\\b.*\\b(main|master)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Push to main/master — verify changes before pushing",
            builtIn: true
        ),

        // ── Commit checkpoint (non-overridable: a broad allow rule can't silence it) ──
        // Tolerates git global options before the subcommand (`-C <path>`, `-c k=v`,
        // `--no-pager`) so `git -C /repo commit` can't slip past the bare-form pattern.
        PersistentRule(
            toolName: "Bash",
            pattern: "\\bgit\\b(\\s+-{1,2}\\S+(\\s+\\S+)?)*\\s+commit\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Commit checkpoint — review staged changes before recording history",
            builtIn: true,
            overridable: false
        ),

        // ── Infrastructure apply/destroy: prompt by default, plan overlay can pre-authorize ──
        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(cdk\\s+(deploy|destroy)|terraform\\s+(apply|destroy)|sam\\s+deploy|pulumi\\s+up|kubectl\\s+(apply|delete)|aws\\s+cloudformation\\s+deploy)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Infrastructure apply/destroy — review the changeset/plan before mutating real resources",
            builtIn: true
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
    /// When true (default), a user allow rule or plan-policy overlay can override this
    /// built-in prompt. False marks a hard checkpoint that allow rules can't silence
    /// (e.g. git commit). Only consulted for builtIn prompt rules.
    let overridable: Bool
    /// Skip this rule during evaluation when true. Persisted so the disable
    /// survives daemon restarts (so a forgotten "temporarily off" rule still
    /// surfaces in the UI rather than silently re-engaging on reboot). Toggle
    /// from the Rules tab; defaults to false (rule active).
    var isDisabled: Bool

    /// Pre-compiled regex (rebuilt on first access, not persisted).
    private var _compiledRegex: NSRegularExpression?
    var compiledRegex: NSRegularExpression? {
        mutating get {
            if _compiledRegex == nil {
                _compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
            }
            return _compiledRegex
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, toolName, pattern, isRegex, verdict, createdAt, explanation, builtIn, overridable, isDisabled
    }

    /// Backward-compatible decoding — isRegex, explanation, builtIn, isDisabled
    /// all default for old rules.json files lacking the field.
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
    }

    init(
        toolName: String,
        pattern: String,
        isRegex: Bool = false,
        verdict: DecisionVerdict,
        explanation: String? = nil,
        builtIn: Bool = false,
        overridable: Bool = true,
        isDisabled: Bool = false
    ) {
        self.id = UUID()
        self.toolName = toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.createdAt = Date()
        self.name = "\(toolName): \(isRegex ? "/" : "")\(pattern)\(isRegex ? "/" : "")"
        self.explanation = explanation
        self.builtIn = builtIn
        self.overridable = overridable
        self.isDisabled = isDisabled
        self._compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
    }

    /// Update a rule's editable fields while preserving identity (id, toolName, createdAt, builtIn).
    init(replacing old: PersistentRule, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String?) {
        self.id = old.id
        self.toolName = old.toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.createdAt = old.createdAt
        self.name = "\(old.toolName): \(isRegex ? "/" : "")\(pattern)\(isRegex ? "/" : "")"
        self.explanation = explanation
        self.builtIn = old.builtIn
        self.overridable = old.overridable
        self.isDisabled = old.isDisabled
        self._compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
    }

    mutating func matches(toolName: String, command: String?, filePath: String?) -> Bool {
        guard self.toolName == toolName || self.toolName == "*" else { return false }

        let raw: String
        switch toolName {
        case "Bash":
            raw = command ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep":
            raw = filePath ?? command ?? ""
        default:
            raw = command ?? filePath ?? ""
        }

        // Sanitize typographic dashes so patterns match consistently
        let target = raw
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2012}", with: "-")

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
                let expandedTarget = expanded
                    .replacingOccurrences(of: "\u{2013}", with: "-")
                    .replacingOccurrences(of: "\u{2014}", with: "--")
                    .replacingOccurrences(of: "\u{2012}", with: "-")
                let strippedExpanded = PatternMatcher.stripQuotedContent(expandedTarget)
                if matchesRegex(regex, in: strippedExpanded) {
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

    /// Compile a pattern to regex. Glob patterns are converted; regex patterns used as-is.
    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        PatternCompiler.compilePattern(pattern, isRegex: isRegex)
    }

    /// Test a pattern against a sample string. Returns match result and any regex error.
    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        PatternCompiler.testPattern(pattern, isRegex: isRegex, against: sample)
    }
}
