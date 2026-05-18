import Foundation

/// The agent CLI that owns a session — Claude Code or OpenAI Codex.
enum AgentKind: String, Codable {
    case claude
    case codex
}

/// State for one agent session (Claude Code or Codex CLI). One row in the monitor.
final class Session: ObservableObject, Identifiable {
    let pid: Int
    let startedAt: Date
    let agent: AgentKind

    @Published var sessionId: String?
    @Published var cwd: String?
    @Published var model: String?
    @Published var label: String = ""
    @Published var isPaused: Bool = false
    @Published var isAlive: Bool = true
    @Published var endedAt: Date?
    @Published var isAutoApproveEnabled: Bool = false
    @Published var isSubAgentInheritEnabled: Bool = false
    @Published var lastPrompt: String?

    /// Set on each tool call so the monitor row can flash for 5s; cleared back to nil afterward. Not durable — don't use for stats.
    @Published var lastActivityAt: Date?

    @Published var autoApproveUntil: Date?

    @Published var sessionRules: [SessionRule] = []

    /// Prompt-rule IDs silenced for this session. Transient; cleared on revoke.
    @Published var suppressedRuleIds: Set<UUID> = []

    // NOT @Published on purpose — mutated on every PreToolUse from background threads, and @Published from non-main deadlocked workers after accept() under load (freeze investigation 2026-05-04). UI reads via the 2s stats timer in MonitorViewModel that fires objectWillChange.send().
    let stats = SessionStats()

    // NOT @Published — TaintedPathStore is thread-safe and exposes .count/.sorted()/.isEmpty for UI direct-read.
    let taintedPaths = TaintedPathStore()

    var toolCallCount: Int { stats.toolCallCount }
    var allowCount: Int { stats.allowCount }
    var blockCount: Int { stats.blockCount }

    var id: Int { pid }

    /// PID reuse can produce a live + dead session with the same PID; `isAlive` and `sessionId` disambiguate.
    var rowIdentity: String {
        "\(pid)-\(isAlive ? "live" : "dead")-\(sessionId ?? "")"
    }

    var isAutoApproveActive: Bool {
        guard let until = autoApproveUntil else { return false }
        return until > Date()
    }

    var autoApproveRemaining: TimeInterval? {
        guard let until = autoApproveUntil else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    init(pid: Int, cwd: String? = nil, startedAt: Date? = nil, agent: AgentKind = .claude) {
        self.pid = pid
        self.startedAt = startedAt ?? Date()
        self.cwd = cwd
        self.agent = agent
    }

    func revokeAutoApprove() {
        isAutoApproveEnabled = false
        isSubAgentInheritEnabled = false
        autoApproveUntil = nil
        sessionRules.removeAll()
        suppressedRuleIds.removeAll()
    }

    func matchesSessionRule(toolName: String, command: String?, filePath: String?) -> SessionRule? {
        sessionRules.first { $0.verdict == .allow && $0.matches(toolName: toolName, command: command, filePath: filePath) }
    }

    func matchesSessionDeny(toolName: String, command: String?, filePath: String?) -> SessionRule? {
        sessionRules.first { $0.verdict == .block && $0.matches(toolName: toolName, command: command, filePath: filePath) }
    }
}

/// Wildcard pattern rule scoped to one session. `*` matches any sequence. Bash commands match per-segment (split on `&&`/`||`/`;`/`|`) so chaining can't poison the match.
struct SessionRule: Identifiable {
    let id = UUID()
    let toolName: String
    let pattern: String
    let verdict: DecisionVerdict
    let explanation: String?

    init(toolName: String, pattern: String, verdict: DecisionVerdict = .allow, explanation: String? = nil) {
        self.toolName = toolName
        self.pattern = pattern
        self.verdict = verdict
        self.explanation = explanation
    }

    func matches(toolName: String, command: String?, filePath: String?) -> Bool {
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

        if toolName == "Bash" {
            // Require EVERY segment to match — `swift build*` matches `swift build` but rejects `swift build && curl evil.com`.
            let segments = Self.splitCommandSegments(target)
            return !segments.isEmpty && segments.allSatisfy { globMatch(pattern: pattern, string: $0) }
        }

        return globMatch(pattern: pattern, string: target)
    }

    private func globMatch(pattern: String, string: String) -> Bool {
        guard let regex = PatternCompiler.compileGlob(pattern) else { return false }
        return PatternCompiler.matches(regex, in: string)
    }

    static func splitCommandSegments(_ command: String) -> [String] {
        let pattern = #"&&|\|\||\||;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [command]
        }
        let nsCommand = command as NSString
        var segments: [String] = []
        var lastEnd = 0

        let matches = regex.matches(in: command, range: NSRange(location: 0, length: nsCommand.length))
        for match in matches {
            let segRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            let seg = nsCommand.substring(with: segRange).trimmingCharacters(in: .whitespaces)
            if !seg.isEmpty { segments.append(seg) }
            lastEnd = match.range.location + match.range.length
        }

        let remaining = nsCommand.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty { segments.append(remaining) }

        return segments
    }

    /// Initial pattern suggestion shown in the approval panel. User can edit (e.g. add `*`) to broaden.
    static func suggestPattern(toolName: String, command: String?, filePath: String?) -> String {
        switch toolName {
        case "Bash":
            guard let cmd = command, !cmd.isEmpty else { return "*" }
            return cmd

        case "Edit", "MultiEdit", "Write":
            guard let path = filePath else { return "*" }
            let components = path.split(separator: "/")
            if components.count >= 2 {
                let dir = components.dropLast().suffix(2).joined(separator: "/")
                return "\(dir)/*"
            }
            return "*"

        case "Read", "Glob", "Grep":
            return "*"

        default:
            return "*"
        }
    }
}
