import Foundation

/// Matches tool calls against dangerous patterns that should always be blocked.
///
/// Two categories:
/// 1. **Bash command patterns** — regex matching against command strings
/// 2. **Protected path patterns** — block Write/Edit to sensitive file paths
struct PatternMatcher {

    /// Pre-compiled dangerous bash command patterns.
    private let bashPatterns: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled protected file path patterns (for Write/Edit tools).
    private let protectedPaths: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled sensitive read patterns (for Read tool — secrets/keys only).
    private let sensitiveReads: [(regex: NSRegularExpression, reason: String)]

    init() {
        let rawBash: [(pattern: String, reason: String)] = [
            // ── Credential exfiltration (expanded) ──
            // curl with any data-sending flag
            ("\\bcurl\\b.*(-d|--data|--data-raw|--data-binary|--data-urlencode|-F|--form|--upload-file|-T)\\b", "Potential data exfiltration via curl"),
            // curl with URL containing variable/subshell expansion (exfil via URL)
            ("\\bcurl\\b.*\\$\\(", "Potential exfiltration via curl with command substitution"),
            // wget POST
            ("\\bwget\\b.*--post-(data|file)", "Potential data exfiltration via wget"),
            // python/ruby/perl network exfil
            ("\\b(python3?|ruby|perl)\\b.*\\b(urlopen|urllib|requests\\.|Net::HTTP|socket\\.connect|TCPSocket|IO\\.popen)", "Scripting language network exfiltration"),
            // openssl data exfil
            ("\\bopenssl\\b.*s_client.*connect", "Potential exfiltration via openssl"),
            // scp/rsync to remote
            ("\\b(scp|rsync)\\b.*:", "Potential file exfiltration via scp/rsync"),
            // dns exfiltration
            ("\\b(dig|nslookup|host)\\b.*\\$\\(", "Potential DNS exfiltration"),

            // ── Environment variable theft (expanded) ──
            ("\\b(env|printenv|set)\\b.*[|].*\\b(curl|wget|nc|ncat|python|ruby|perl)", "Piping environment to network command"),
            ("\\b(env|printenv|set)\\b.*>\\s*/tmp/", "Environment variables written to temp file"),
            ("\\bcurl\\b.*-d.*\\$\\(\\s*(env|printenv|set)\\b", "Environment exfiltration via curl subshell"),

            // ── Reverse shells (expanded) ──
            ("\\bbash\\s+-i\\s+>&", "Reverse shell pattern detected"),
            ("/dev/tcp/", "Reverse shell via /dev/tcp"),
            ("\\b(nc|ncat)\\b.*(-e|--exec|--sh-exec)\\s+/", "Netcat reverse shell"),
            ("\\b(python3?|ruby|perl)\\b.*socket.*connect.*\\b(exec|spawn|system|dup2)\\b", "Scripting reverse shell"),
            ("\\bsocat\\b.*exec.*tcp", "Socat reverse shell"),
            ("\\bzsh\\s+-i\\s+>&", "Zsh reverse shell"),
            ("\\bphp\\b.*fsockopen.*exec", "PHP reverse shell"),

            // ── Persistence mechanisms (expanded) ──
            ("\\bcrontab\\b", "Crontab modification"),
            ("\\blaunchctl\\b\\s+(load|unload|submit|bootstrap|bootout|enable|disable|kickstart)", "LaunchAgent/Daemon modification"),
            ("\\bat\\b\\s+", "at job scheduling"),

            // ── Destructive operations (expanded) ──
            ("\\brm\\s+(-\\w*[rR]\\w*\\s+)*/(?!tmp\\b)", "Recursive delete from root"),
            ("\\brm\\s+(-\\w*[rR]\\w*\\s+)*\\./", "Recursive delete from current directory"),
            ("\\brm\\s+(-\\w*[rR]\\w*\\s+)*\\.\\./", "Recursive delete from parent directory"),
            ("\\brm\\s+--recursive", "Recursive delete (long flag)"),
            ("\\bmkfs\\b", "Filesystem format command"),
            ("\\bdd\\b\\s+.*of=/dev/", "Direct disk write"),

            // ── SSH/GPG key access (expanded) ──
            ("\\b(cat|head|tail|less|more|cp|mv|base64|xxd|openssl)\\b.*\\.ssh/(id_|authorized|known_hosts)", "SSH key/config access"),
            ("\\b(cat|head|tail|less|more|cp|mv|base64)\\b.*\\.gnupg/", "GPG key access"),

            // ── Gavel self-protection ──
            ("\\b(pkill|killall)\\b.*\\bgav", "Attempt to kill Gavel daemon"),
            ("\\bkill\\b.*\\b(pgrep|pidof)\\b.*gav", "Attempt to kill Gavel daemon"),
            ("\\brm\\b.*gavel\\.sock", "Attempt to remove Gavel socket"),
            ("\\brm\\b.*\\.claude/gavel/", "Attempt to delete Gavel config"),
            // Block killing by PID if the command discovers the PID first
            ("\\bkill\\b.*\\$\\(.*gav", "Attempt to kill Gavel via PID lookup"),

            // ── Command obfuscation ──
            ("\\beval\\b.*\\$\\(.*\\b(base64|b64decode)\\b", "Obfuscated command via eval+base64"),
            ("\\bbase64\\s+-[dD]\\b.*\\|.*\\b(bash|sh|zsh)\\b", "Base64 decoded pipe to shell"),
            ("\\bbash\\s*<<", "Heredoc execution (potential obfuscation)"),
        ]

        let rawPaths: [(pattern: String, reason: String)] = [
            // SSH keys and config
            ("\\.ssh/(id_|authorized_keys|config)", "Protected: SSH keys/config"),
            // GPG keys
            ("\\.gnupg/", "Protected: GPG keys"),
            // Gavel's own config
            ("\\.claude/gavel/(rules\\.json|session-defaults\\.json|hooks/|bin/)", "Protected: Gavel config"),
            // Claude Code hooks and settings
            ("\\.claude/(settings\\.json|settings\\.local\\.json|hooks/)", "Protected: Claude Code settings/hooks"),
            // Shell config (persistence vector)
            ("\\.(bash_profile|bashrc|zshrc|zprofile|profile|zshenv)$", "Protected: Shell config (persistence risk)"),
            // LaunchAgents (persistence vector)
            ("LaunchAgents/", "Protected: LaunchAgent (persistence risk)"),
            ("LaunchDaemons/", "Protected: LaunchDaemon (persistence risk)"),
            // AWS/cloud credentials
            ("\\.aws/(credentials|config)", "Protected: AWS credentials"),
            ("\\.kube/config", "Protected: Kubernetes config"),
            // Environment files
            ("\\.env$", "Protected: Environment file"),
        ]

        bashPatterns = rawBash.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        protectedPaths = rawPaths.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        let rawSensitiveReads: [(pattern: String, reason: String)] = [
            // SSH private keys
            ("\\.ssh/(id_|id_rsa|id_ed25519|id_ecdsa)", "Blocked: SSH private key read"),
            // GPG private keys
            ("\\.gnupg/(private-keys|secring|trustdb)", "Blocked: GPG private key read"),
            // AWS credentials
            ("\\.aws/credentials", "Blocked: AWS credentials read"),
            // Kubernetes secrets
            ("\\.kube/config", "Blocked: Kubernetes config read"),
            // Environment files with secrets
            ("\\.env$", "Blocked: Environment file read"),
            ("\\.env\\.local$", "Blocked: Local environment file read"),
            // Gavel rules (prevent reading to reverse-engineer deny patterns)
            ("\\.claude/gavel/rules\\.json", "Blocked: Gavel rules read"),
            // Keychain
            ("Keychains/", "Blocked: Keychain access"),
            // Token/credential files
            ("\\.(token|secret|credentials|key)$", "Blocked: Credential file read"),
            // NPM/Docker/Hub tokens
            ("\\.npmrc$", "Blocked: NPM config (may contain tokens)"),
            ("\\.docker/config\\.json", "Blocked: Docker config (may contain tokens)"),
            ("\\.netrc$", "Blocked: netrc credentials"),
        ]

        sensitiveReads = rawSensitiveReads.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        mcpPatterns = Self.dangerousMcpTools.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }
    }

    /// MCP tools that can exfiltrate or modify data — blocked unless user has an explicit allow rule.
    private static let dangerousMcpTools: [(pattern: String, reason: String)] = [
        // Messaging — send, update, delete (exfil + evidence destruction)
        ("mcp__.*[Ss]lack.*(send|update|delete|upload)", "MCP: Slack write operation"),
        // Browser — can navigate to attacker URLs with data in params
        ("mcp__.*[Pp]laywright.*(navigate$|evaluate|type|fill|click|run_code)", "MCP: Browser interaction (potential exfiltration)"),
        // Email
        ("mcp__.*mail.*(send|create|draft)", "MCP: Email write operation"),
        // Webhooks / HTTP
        ("mcp__.*webhook.*(send|create|trigger)", "MCP: Webhook operation"),
        ("mcp__.*http.*(post|put|patch|delete)", "MCP: HTTP write operation"),
        // Jira/Todoist — write operations (create, update, delete, comment)
        ("mcp__.*[Jj]ira.*(create|update|delete|add|edit|transition|link)", "MCP: Jira write operation"),
        ("mcp__.*[Tt]odoist.*(create|update|delete|close)", "MCP: Todoist write operation"),
    ]

    /// Pre-compiled MCP tool patterns (compiled once at init).
    private let mcpPatterns: [(regex: NSRegularExpression, reason: String)]

    /// Check if a PreToolUse payload matches any dangerous pattern.
    /// Returns a reason string if dangerous, nil if safe.
    ///
    /// Note: MCP tools are checked separately via `matchMcpDangerous` because
    /// they should be overridable by persistent allow rules (unlike Bash/Write
    /// patterns which are absolute blocks).
    func matchDangerous(payload: PreToolUsePayload) -> String? {
        switch payload.toolName {
        case "Bash":
            return matchBashCommand(payload.command)
        case "Write", "Edit", "MultiEdit":
            return matchProtectedPath(payload.filePath)
        case "Read":
            return matchSensitiveRead(payload.filePath)
        default:
            return nil
        }
    }

    /// Check MCP tools separately — these are overridable by persistent allow rules.
    /// Called from ApprovalEngine AFTER allow rules are checked.
    func matchMcpDangerous(payload: PreToolUsePayload) -> String? {
        guard payload.toolName.hasPrefix("mcp__") else { return nil }
        return matchMcpTool(payload.toolName)
    }

    // MARK: - Bash command matching

    private func matchBashCommand(_ command: String?) -> String? {
        guard let command = command else { return nil }

        // Match against the full command first (catches everything)
        let range = NSRange(command.startIndex..., in: command)
        for (regex, reason) in bashPatterns {
            if regex.firstMatch(in: command, range: range) != nil {
                // Verify it's not a false positive inside a quoted string.
                // If the match disappears when we strip quoted content,
                // it was just a string literal (commit message, echo, etc.)
                let stripped = Self.stripQuotedContent(command)
                let strippedRange = NSRange(stripped.startIndex..., in: stripped)
                if regex.firstMatch(in: stripped, range: strippedRange) != nil {
                    return reason
                }
                // Match was only in a quoted string — false positive
            }
        }
        return nil
    }

    /// Strip message/string-literal content to reduce false positives.
    /// Only strips quoted args after message-like flags (-m, --message, --body).
    /// Does NOT strip code arguments (python -c, ruby -e, perl -e).
    /// "git commit -m 'fixed curl issue'" → "git commit -m ''"
    /// "echo 'curl -d foo'" → "echo ''"
    static func stripQuotedContent(_ command: String) -> String {
        var result = command

        // Strip quoted content after message flags: -m, --message, --body, --title
        if let regex = try? NSRegularExpression(pattern: #"(-m|--message|--body|--title)\s+"([^"\\]|\\.)*""#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \"\"")
        }
        if let regex = try? NSRegularExpression(pattern: #"(-m|--message|--body|--title)\s+'[^']*'"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ''")
        }

        // Strip echo/printf arguments
        if let regex = try? NSRegularExpression(pattern: #"\b(echo|printf)\s+"([^"\\]|\\.)*""#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \"\"")
        }
        if let regex = try? NSRegularExpression(pattern: #"\b(echo|printf)\s+'[^']*'"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ''")
        }

        return result
    }

    // MARK: - Protected path matching (Write/Edit)

    private func matchProtectedPath(_ filePath: String?) -> String? {
        guard let path = filePath else { return nil }

        let range = NSRange(path.startIndex..., in: path)
        for (regex, reason) in protectedPaths {
            if regex.firstMatch(in: path, range: range) != nil {
                return reason
            }
        }
        return nil
    }

    // MARK: - Sensitive read matching (Read tool)

    private func matchSensitiveRead(_ filePath: String?) -> String? {
        guard let path = filePath else { return nil }

        let range = NSRange(path.startIndex..., in: path)
        for (regex, reason) in sensitiveReads {
            if regex.firstMatch(in: path, range: range) != nil {
                return reason
            }
        }
        return nil
    }

    // MARK: - MCP tool matching

    private func matchMcpTool(_ toolName: String) -> String? {
        let range = NSRange(toolName.startIndex..., in: toolName)
        for (regex, reason) in mcpPatterns {
            if regex.firstMatch(in: toolName, range: range) != nil {
                return reason
            }
        }
        return nil
    }
}
