import Foundation

/// Matches tool calls against dangerous patterns that should always be blocked.
struct PatternMatcher {

    /// Dangerous bash command patterns that are always blocked.
    private let dangerousPatterns: [(pattern: String, reason: String)] = [
        // Credential exfiltration
        ("curl.*(-d|--data).*\\b(key|token|secret|password|credential)", "Potential credential exfiltration via curl"),
        ("wget.*\\b(key|token|secret|password|credential)", "Potential credential exfiltration via wget"),

        // Environment variable theft
        ("\\benv\\b.*\\|.*\\b(curl|wget|nc|ncat)", "Piping environment to network command"),
        ("printenv.*\\|.*\\b(curl|wget|nc|ncat)", "Piping environment to network command"),

        // Reverse shells
        ("\\bbash\\s+-i\\s+>&", "Reverse shell pattern detected"),
        ("/dev/tcp/", "Reverse shell via /dev/tcp"),
        ("\\bnc\\b.*-e\\s+/bin/(ba)?sh", "Netcat reverse shell"),

        // Persistence mechanisms
        ("crontab\\s+-", "Crontab modification"),
        ("launchctl\\s+(load|submit)", "LaunchAgent/Daemon installation"),

        // Destructive operations
        ("rm\\s+-rf\\s+/(?!tmp)", "Recursive delete from root"),
        ("mkfs\\b", "Filesystem format command"),
        ("dd\\s+.*of=/dev/", "Direct disk write"),

        // SSH/GPG key exfiltration
        ("cat.*\\.ssh/(id_|authorized)", "SSH key access"),
        ("cat.*\\.gnupg/", "GPG key access"),
    ]

    /// Check if a PreToolUse payload matches any dangerous pattern.
    /// Returns a reason string if dangerous, nil if safe.
    func matchDangerous(payload: PreToolUsePayload) -> String? {
        guard payload.toolName == "Bash", let command = payload.command else {
            return nil
        }

        for (pattern, reason) in dangerousPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                return reason
            }
        }

        return nil
    }
}
