import Foundation

/// Persistent rule storage for approval decisions.
///
/// Rules are loaded from a JSON config file and can be modified
/// at runtime via the approval panel ("Always Deny" / "Always Allow").
/// Deny rules take absolute priority — they block even under auto-approve.
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [PersistentRule] = []
    private let configPath: String

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
                return Decision(verdict: .block, reason: "Always deny: \(rules[i].name)")
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

    func evaluatePrompt(payload: PreToolUsePayload) -> Decision? {
        for i in rules.indices where rules[i].verdict == .prompt {
            if rules[i].matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Always prompt: \(rules[i].name)", askUser: true)
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
        rules.removeAll { $0.id == id }
        saveRules()
    }

    var denyRules: [PersistentRule] {
        rules.filter { $0.verdict == .block }
    }

    var allowRules: [PersistentRule] {
        rules.filter { $0.verdict == .allow }
    }

    // MARK: - Persistence

    private func loadRules() {
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            return
        }
        rules = (try? JSONDecoder().decode([PersistentRule].self, from: data)) ?? []
    }

    private func saveRules() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(rules) {
            FileManager.default.createFile(atPath: configPath, contents: data)
        }
    }
}

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
        case id, name, toolName, pattern, isRegex, verdict, createdAt
    }

    /// Backward-compatible decoding — isRegex defaults to false for old rules.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        toolName = try c.decode(String.self, forKey: .toolName)
        pattern = try c.decode(String.self, forKey: .pattern)
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        verdict = try c.decode(DecisionVerdict.self, forKey: .verdict)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    init(
        toolName: String,
        pattern: String,
        isRegex: Bool = false,
        verdict: DecisionVerdict
    ) {
        self.id = UUID()
        self.toolName = toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.createdAt = Date()
        self.name = "\(toolName): \(isRegex ? "/" : "")\(pattern)\(isRegex ? "/" : "")"
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

        // Match against command/filePath first
        if regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil {
            return true
        }

        // For wildcard rules, also match against the tool name itself.
        // MCP tools carry their identity in the name (e.g. mcp__LinkedIn__linkedin_create_post)
        // and typically have no command or filePath.
        if self.toolName == "*" {
            return regex.firstMatch(in: toolName, range: NSRange(toolName.startIndex..., in: toolName)) != nil
        }

        return false
    }

    /// Compile a pattern to regex. Glob patterns are converted; regex patterns used as-is.
    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        if isRegex {
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        // Convert glob to regex
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case ".","(",")","[","]","{","}","\\","^","$","|","+","?":
                regex += "\\\(ch)"
            default: regex += String(ch)
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex)
    }

    /// Test a pattern against a sample string. Returns match result and any regex error.
    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return (false, "Invalid regex")
            }
            let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil
            return (match, nil)
        }
        guard let regex = compilePattern(pattern, isRegex: false) else {
            return (false, "Invalid pattern")
        }
        let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil
        return (match, nil)
    }
}
