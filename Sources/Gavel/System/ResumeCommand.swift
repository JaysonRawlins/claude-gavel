import Foundation

/// Builds the shell command users paste to resume a sleeping session — `cd '<cwd>' && <agent>-resume`.
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

    /// Bash single-quote escape: close-quote → escape → reopen for each embedded apostrophe.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
