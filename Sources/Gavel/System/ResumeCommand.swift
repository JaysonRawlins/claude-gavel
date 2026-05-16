import Foundation

enum ResumeCommand {
    static func build(pid: Int, sessionId: String, cwd: String?) -> String {
        let claudeInvocation = "claude --name \(pid) --resume \(sessionId)"
        guard let cwd = cwd else { return claudeInvocation }
        return "cd \(shellQuote(cwd)) && \(claudeInvocation)"
    }

    /// Bash single-quote escaping: close-quote, escape, reopen for each embedded apostrophe.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
