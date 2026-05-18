import Foundation

enum ResumeCommand {
    static func build(pid: Int, sessionId: String, cwd: String?, agent: AgentKind = .claude) -> String {
        let invocation: String
        switch agent {
        case .claude:
            invocation = "claude --name \(pid) --resume \(sessionId)"
        case .codex:
            invocation = "codex resume \(sessionId)"
        }
        guard let cwd = cwd else { return invocation }
        return "cd \(shellQuote(cwd)) && \(invocation)"
    }

    /// Bash single-quote escaping: close-quote, escape, reopen for each embedded apostrophe.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
