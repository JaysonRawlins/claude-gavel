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

    /// Current seed version — bump when adding new default rules.
    private static let seedVersion = 6

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
        for i in rules.indices where rules[i].verdict == .block {
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
        for i in rules.indices where rules[i].verdict == .allow {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .allow, reason: "Always allow: \(rules[i].name)")
            }
        }
        return nil
    }

    /// User-created prompt rules — high priority, checked before allow rules.
    func evaluateUserPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && !rules[i].builtIn {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Always prompt: \(rules[i].name)", askUser: true)
            }
        }
        return nil
    }

    /// Built-in prompt rules — lower priority, checked after allow rules so users can override.
    func evaluateBuiltInPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Default rule: \(rules[i].name)", askUser: true)
            }
        }
        return nil
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
        PersistentRule(
            toolName: "Bash",
            pattern: "\\.claude/(gavel/|settings|hooks/)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Bash command references Gavel/Claude config — session allow for legitimate use",
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

        if fileVersion < Self.seedVersion {
            seedDefaults(existingRules: rules, version: fileVersion, deleted: deletedBuiltInPatterns)
        }
    }

    private func seedDefaults(existingRules: [PersistentRule], version: Int, deleted: [String]) {
        let existingPatterns = Set(existingRules.map(\.pattern))
        let deletedSet = Set(deleted)

        var seeded = existingRules
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

    private func saveRules() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let file = RulesFile(version: fileVersion, deletedBuiltInPatterns: deletedBuiltInPatterns, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(file) {
            FileManager.default.createFile(atPath: configPath, contents: data)
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
        case id, name, toolName, pattern, isRegex, verdict, createdAt, explanation, builtIn
    }

    /// Backward-compatible decoding — isRegex, explanation, builtIn default for old rules.json.
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
    }

    init(
        toolName: String,
        pattern: String,
        isRegex: Bool = false,
        verdict: DecisionVerdict,
        explanation: String? = nil,
        builtIn: Bool = false
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
