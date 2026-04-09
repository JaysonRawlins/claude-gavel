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
        for rule in rules where rule.verdict == .block {
            if rule.matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .block, reason: "Always deny: \(rule.name)")
            }
        }
        return nil
    }

    func evaluateAllow(payload: PreToolUsePayload) -> Decision? {
        for rule in rules where rule.verdict == .allow {
            if rule.matches(toolName: payload.toolName, command: payload.command, filePath: payload.filePath) {
                return Decision(verdict: .allow, reason: "Always allow: \(rule.name)")
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
/// Uses glob-style wildcards (* matches any characters).
struct PersistentRule: Codable, Identifiable {
    let id: UUID
    let name: String
    let toolName: String
    let pattern: String
    let verdict: DecisionVerdict
    let createdAt: Date

    init(
        toolName: String,
        pattern: String,
        verdict: DecisionVerdict
    ) {
        self.id = UUID()
        self.name = "\(toolName): \(pattern)"
        self.toolName = toolName
        self.pattern = pattern
        self.verdict = verdict
        self.createdAt = Date()
    }

    func matches(toolName: String, command: String?, filePath: String?) -> Bool {
        guard self.toolName == toolName || self.toolName == "*" else { return false }

        let target: String
        switch toolName {
        case "Bash":
            target = command ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep":
            target = filePath ?? command ?? ""
        default:
            target = command ?? filePath ?? ""
        }

        return globMatch(pattern: pattern, string: target)
    }

    private func globMatch(pattern: String, string: String) -> Bool {
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
        return (try? NSRegularExpression(pattern: regex))
            .flatMap { $0.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) } != nil
    }
}
