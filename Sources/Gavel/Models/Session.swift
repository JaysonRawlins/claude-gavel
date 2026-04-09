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
    @Published var lastPrompt: String?

    // Timed auto-approve
    @Published var autoApproveUntil: Date?

    // Session rules — wildcard patterns for auto-approval
    @Published var sessionRules: [SessionRule] = []

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

        return globMatch(pattern: pattern, string: target)
    }

    /// Simple glob matching: `*` matches any sequence of characters.
    private func globMatch(pattern: String, string: String) -> Bool {
        // Convert glob to regex: escape everything except *, then * → .*
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
