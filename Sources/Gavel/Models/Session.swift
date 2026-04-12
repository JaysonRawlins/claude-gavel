import Foundation

/// Tracks state for a single Claude Code session.
final class Session: ObservableObject, Identifiable {
    let pid: Int
    let startedAt: Date

    @Published var sessionId: String?
    @Published var cwd: String?
    @Published var model: String?
    @Published var isPaused: Bool = false
    @Published var isAlive: Bool = true
    @Published var isAutoApproveEnabled: Bool = false
    @Published var isSubAgentInheritEnabled: Bool = false
    @Published var lastPrompt: String?

    // Timed auto-approve
    @Published var autoApproveUntil: Date?

    // Session rules — wildcard patterns for auto-approval
    @Published var sessionRules: [SessionRule] = []

    // Taint tracking — temp files that contain sensitive data
    @Published var taintedPaths: Set<String> = []

    // Stats
    @Published var toolCallCount: Int = 0
    @Published var allowCount: Int = 0
    @Published var blockCount: Int = 0

    var id: Int { pid }

    var isAutoApproveActive: Bool {
        guard let until = autoApproveUntil else { return false }
        return until > Date()
    }

    var autoApproveRemaining: TimeInterval? {
        guard let until = autoApproveUntil else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    init(pid: Int, cwd: String? = nil) {
        self.pid = pid
        self.startedAt = Date()
        self.cwd = cwd
    }

    func revokeAutoApprove() {
        isAutoApproveEnabled = false
        autoApproveUntil = nil
        sessionRules.removeAll()
    }

    /// Check if a tool call matches any session rule.
    func matchesSessionRule(toolName: String, command: String?, filePath: String?) -> SessionRule? {
        for rule in sessionRules {
            if rule.matches(toolName: toolName, command: command, filePath: filePath) {
                return rule
            }
        }
        return nil
    }
}

/// A wildcard pattern rule for session-scoped auto-approval.
///
/// Examples:
///   - `Bash: swift build*`  — matches any swift build command
///   - `Bash: git *`         — matches any git command
///   - `Edit: Sources/*`     — matches edits to files under Sources/
///   - `Read: *`             — matches all reads
struct SessionRule: Identifiable {
    let id = UUID()
    let toolName: String
    let pattern: String

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
            let parts = cmd.split(separator: " ", maxSplits: 2)
            if parts.count >= 2 {
                // "swift build -c release" → "swift build*"
                return "\(parts[0]) \(parts[1])*"
            }
            return "\(parts[0]) *"

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
