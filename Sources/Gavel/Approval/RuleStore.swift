import Foundation

/// Persistent rule storage — deny/allow/prompt rules in rules.json, mutable via the approval panel. Deny rules block even under auto-approve.
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [PersistentRule] = []
    private var deletedBuiltInPatterns: [String] = []
    private var fileVersion: Int = 0
    private let configPath: String

    /// Bump when adding new default rules so existing installs pick them up on next launch.
    private static let seedVersion = 7

    init(configPath: String? = nil) {
        self.configPath = configPath ?? Self.defaultConfigPath
        loadRules()
    }

    static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/gavel/rules.json"
    }

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

    /// User-created prompt rules — checked before allow rules so they can't be silently bypassed.
    func evaluateUserPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && !rules[i].builtIn && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Always prompt: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    /// Built-in prompt rules — lower priority than user rules and allow rules so users can override seeded defaults.
    func evaluateBuiltInPrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt && rules[i].builtIn && !rules[i].isDisabled {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Default rule: \(rules[i].name)", askUser: true, triggeringRuleId: rules[i].id)
            }
        }
        return nil
    }

    func rule(for id: UUID) -> PersistentRule? {
        rules.first { $0.id == id }
    }

    func setDisabled(id: UUID, isDisabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isDisabled = isDisabled
        saveRules()
    }

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

    static let seededDefaults: [PersistentRule] = [
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

        PersistentRule(
            toolName: "Bash",
            pattern: "\\.claude/(gavel/|settings|hooks/)",
            isRegex: true,
            verdict: .prompt,
            explanation: "Bash command references Gavel/Claude config — session allow for legitimate use",
            builtIn: true
        ),

        PersistentRule(
            toolName: "apply_patch",
            pattern: "\\.claude/(gavel/|settings|hooks/)|\\.codex/(config|hooks)|\\.(zshrc|bashrc|bash_profile|profile)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "apply_patch references Gavel/Claude/Codex config or shell init — verify intent",
            builtIn: true
        ),

        PersistentRule(
            toolName: "Bash",
            pattern: "\\b(python3?|ruby|perl|node|php|lua)\\b\\s+(-[ce]|--eval)\\b",
            isRegex: true,
            verdict: .prompt,
            explanation: "Inline script execution — can bypass pattern matching via string construction",
            builtIn: true
        ),

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

        PersistentRule(
            toolName: "Bash",
            pattern: "\\bcurl\\b.*\\bfile://",
            isRegex: true,
            verdict: .prompt,
            explanation: "curl file:// reads local files — bypasses Read tool protections",
            builtIn: true
        ),

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

        // Scheduler tools: `toolName="*"` + anchored regex is intentional — seed dedup keys on pattern, so each rule needs a unique pattern string.
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

    private func loadRules() {
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            seedDefaults(existingRules: [], version: 0, deleted: [])
            return
        }

        // Envelope format first; bare-array fallback handles rules.json files written by versions before seedVersion existed.
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

/// On-disk rules.json envelope — wraps rules with seed-version metadata.
struct RulesFile: Codable {
    var version: Int
    var deletedBuiltInPatterns: [String]
    var rules: [PersistentRule]
}

/// A persisted approval rule. `pattern` is a glob (default) or regex (when `isRegex` is true).
struct PersistentRule: Codable, Identifiable {
    let id: UUID
    let name: String
    let toolName: String
    let pattern: String
    let isRegex: Bool
    let verdict: DecisionVerdict
    let createdAt: Date
    let explanation: String?
    let builtIn: Bool
    var isDisabled: Bool

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
        case id, name, toolName, pattern, isRegex, verdict, createdAt, explanation, builtIn, isDisabled
    }

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
        isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
    }

    init(
        toolName: String,
        pattern: String,
        isRegex: Bool = false,
        verdict: DecisionVerdict,
        explanation: String? = nil,
        builtIn: Bool = false,
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
        self.isDisabled = isDisabled
        self._compiledRegex = Self.compilePattern(pattern, isRegex: isRegex)
    }

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

        let target = raw
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2012}", with: "-")

        guard let regex = compiledRegex else { return false }

        if matchesRegex(regex, in: target) {
            if toolName != "Bash" {
                return true
            }
            let stripped = PatternMatcher.stripQuotedContent(target)
            if matchesRegex(regex, in: stripped) {
                return true
            }
        }

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

        if self.toolName == "*" {
            return regex.firstMatch(in: toolName, range: NSRange(toolName.startIndex..., in: toolName)) != nil
        }

        return false
    }

    private func matchesRegex(_ regex: NSRegularExpression, in string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        PatternCompiler.compilePattern(pattern, isRegex: isRegex)
    }

    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        PatternCompiler.testPattern(pattern, isRegex: isRegex, against: sample)
    }
}
