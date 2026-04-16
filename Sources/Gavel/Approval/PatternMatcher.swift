import Foundation

/// Matches tool calls against dangerous patterns that should always be blocked.
///
/// Two categories:
/// 1. **Bash command patterns** — regex matching against command strings
/// 2. **Protected path patterns** — block Write/Edit to sensitive file paths
struct PatternMatcher {

    /// Pre-compiled dangerous bash command patterns — hard block.
    private let bashPatterns: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled bash patterns that force dialog — destructive but sometimes legitimate.
    private let askUserBashPatterns: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled protected file path patterns — hard block (credentials, persistence).
    private let protectedPaths: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled protected file path patterns — force dialog (config, hooks, shell).
    private let askUserPaths: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled sensitive read patterns — hard block (actual secrets).
    private let sensitiveReads: [(regex: NSRegularExpression, reason: String)]

    /// Pre-compiled sensitive read patterns — force dialog (configuration).
    private let askUserReads: [(regex: NSRegularExpression, reason: String)]

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

            // ── Destructive operations (catastrophic, non-recoverable) ──
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

            // ── Compiled/scripted exfiltration via temp files ──
            // Compiling in temp directories
            ("\\b(gcc|g\\+\\+|clang|clang\\+\\+|rustc|javac|swiftc)\\b.*/tmp/", "Compiling code in temp directory"),
            ("\\b(go\\s+build|go\\s+run)\\b.*/tmp/", "Building/running Go code from temp directory"),
            ("\\bcargo\\s+(build|run)\\b.*--manifest-path.*/tmp/", "Building Rust code from temp directory"),
            // Executing scripts from temp directories
            ("\\b(perl|ruby|node|swift|php|lua)\\b\\s+/tmp/", "Running script from temp directory"),
            // Running any executable from /tmp (direct execution)
            ("^\\s*/tmp/\\S+", "Running executable from temp directory"),
            ("&&\\s*/tmp/\\S+", "Running executable from temp directory (chained)"),
            ("\\|\\s*/tmp/\\S+", "Running executable from temp directory (piped)"),
            (";\\s*/tmp/\\S+", "Running executable from temp directory (sequential)"),
            // cd to /tmp then execute (bypass /tmp/ path check)
            ("\\bcd\\s+/tmp\\b.*&&", "Changing to temp directory and executing"),
            // chmod +x on temp files (making them executable)
            ("\\bchmod\\b.*\\+x.*/tmp/", "Making temp file executable"),
        ]

        // Destructive/sensitive bash commands — force dialog instead of hard block
        let rawAskUserBash: [(pattern: String, reason: String)] = [
            // Recursive delete
            ("\\brm\\s+-\\w*[rR]\\w*\\s+/(?!tmp\\b)", "Recursive delete from root path"),
            ("\\brm\\s+-\\w*[rR]\\w*\\s+\\./", "Recursive delete from current directory"),
            ("\\brm\\s+-\\w*[rR]\\w*\\s+\\.\\./", "Recursive delete from parent directory"),
            ("\\brm\\s+--recursive", "Recursive delete (long flag)"),
            // Cloud CLI write operations
            ("\\baz\\s+.*\\b(update|create|delete|set|add|remove|start|stop|restart)\\b", "Azure CLI write operation"),
            ("\\baws\\s+.*\\b(create|delete|update|put|remove|terminate|stop|start|modify|run)\\b(?!.*--dry-run)", "AWS CLI write operation"),
            ("\\bgcloud\\s+.*\\b(create|delete|update|add|remove|start|stop|deploy)\\b", "GCloud CLI write operation"),
        ]

        // Hard block — credentials and persistence vectors that should never be written
        let rawPaths: [(pattern: String, reason: String)] = [
            // SSH keys and config
            ("\\.ssh/(id_|authorized_keys|config)", "Protected: SSH keys/config"),
            // GPG keys
            ("\\.gnupg/", "Protected: GPG keys"),
            // LaunchAgents (persistence vector)
            ("LaunchAgents/", "Protected: LaunchAgent (persistence risk)"),
            ("LaunchDaemons/", "Protected: LaunchDaemon (persistence risk)"),
            // AWS/cloud credentials
            ("\\.aws/(credentials|config)", "Protected: AWS credentials"),
            ("\\.kube/config", "Protected: Kubernetes config"),
            // Environment files
            ("\\.env$", "Protected: Environment file"),
        ]

        // Ask user — config and tools that may legitimately need editing
        let rawAskUserPaths: [(pattern: String, reason: String)] = [
            // Gavel's own config
            ("\\.claude/gavel/(rules\\.json|session-defaults\\.json|hooks/|bin/)", "Sensitive: Gavel config"),
            // Claude Code hooks and settings
            ("\\.claude/(settings\\.json|settings\\.local\\.json|hooks/)", "Sensitive: Claude Code settings/hooks"),
            // Shell config
            ("\\.(bash_profile|bashrc|zshrc|zprofile|profile|zshenv)$", "Sensitive: Shell config"),
        ]

        bashPatterns = rawBash.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        askUserBashPatterns = rawAskUserBash.compactMap { entry in
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

        askUserPaths = rawAskUserPaths.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        // Hard block — actual secrets that should never be read
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
            // Keychain
            ("Keychains/", "Blocked: Keychain access"),
            // Token/credential files
            ("\\.(token|secret|credentials|key)$", "Blocked: Credential file read"),
            // NPM/Docker/Hub tokens
            ("\\.npmrc$", "Blocked: NPM config (may contain tokens)"),
            ("\\.docker/config\\.json", "Blocked: Docker config (may contain tokens)"),
            ("\\.netrc$", "Blocked: netrc credentials"),
        ]

        // Ask user — configuration that may need reading for self-mutation
        let rawAskUserReads: [(pattern: String, reason: String)] = [
            ("\\.claude/gavel/rules\\.json", "Sensitive: Gavel rules read"),
            ("\\.claude/gavel/session-defaults\\.json", "Sensitive: Gavel defaults read"),
        ]

        sensitiveReads = rawSensitiveReads.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, entry.reason)
        }

        askUserReads = rawAskUserReads.compactMap { entry in
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
            if let pathBlock = matchProtectedPath(payload.filePath) {
                return pathBlock
            }
            // Only scan content for files in temp directories — project source files
            // contain pattern strings as literals that trigger false positives
            if let path = payload.filePath, Self.isTempPath(path) {
                let contentToScan = payload.toolInput["content"]?.stringValue
                    ?? payload.toolInput["new_string"]?.stringValue
                if let content = contentToScan {
                    return matchDangerousContent(content)
                }
            }
            return nil
        case "Read":
            return matchSensitiveRead(payload.filePath)
        default:
            return nil
        }
    }

    /// Check sensitive paths that require user confirmation (gavel config, hooks, shell config).
    /// Called from ApprovalEngine AFTER allow rules — returns askUser decision.
    func matchSensitivePath(payload: PreToolUsePayload) -> String? {
        // Bash: check askUser destructive patterns (rm -rf etc.)
        if payload.toolName == "Bash", let command = payload.command {
            let stripped = Self.stripQuotedContent(command)
            let range = NSRange(stripped.startIndex..., in: stripped)
            for (regex, reason) in askUserBashPatterns {
                if regex.firstMatch(in: stripped, range: range) != nil {
                    return reason
                }
            }
        }

        guard let path = payload.filePath else { return nil }
        let range = NSRange(path.startIndex..., in: path)

        // Write/Edit: check askUser write paths
        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName) {
            for (regex, reason) in askUserPaths {
                if regex.firstMatch(in: path, range: range) != nil {
                    return reason
                }
            }
        }

        // Read: check askUser read paths (config files needed for self-mutation)
        if payload.toolName == "Read" {
            for (regex, reason) in askUserReads {
                if regex.firstMatch(in: path, range: range) != nil {
                    return reason
                }
            }
        }

        return nil
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

    // MARK: - Dangerous content scanning (Write tool)

    /// Scans file content for code that both accesses credentials AND sends data over the network.
    /// Blocks polyglot exfil scripts (Rust, C, Go, Perl, etc.) written to temp files.
    private func matchDangerousContent(_ content: String?) -> String? {
        guard let content = content, content.count > GavelConstants.minContentScanLength else { return nil }

        let range = NSRange(content.startIndex..., in: content)

        // Check for credential/sensitive path references in the content
        let credPatterns = [
            "\\.ssh/", "\\.aws/", "\\.gnupg/", "\\.env\\b",
            "\\.kube/config", "\\.npmrc", "\\.netrc", "\\.docker/config",
            "id_rsa", "id_ed25519", "authorized_keys",
            "credentials", "secret_key", "access_key",
        ]
        var hasCredRef = false
        for pattern in credPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: content, range: range) != nil {
                hasCredRef = true
                break
            }
        }
        // Also check for generic file-read + network combo (runtime exfil wrappers)
        // e.g., C code with fopen/fread + system("curl") or socket
        if !hasCredRef {
            // Check for generic file-read patterns (any language)
            let fileReadKeywords = [
                "\\bfopen\\b", "\\bfread\\b",              // C
                "\\bopen\\b.*O_RDONLY",                    // C low-level
                "\\bfs::read\\b", "\\bfs::read_to_string", // Rust
                "\\bFile\\.read\\b",                       // Ruby
                "\\bioutil\\.ReadFile\\b",                 // Go (old)
                "\\bos\\.ReadFile\\b",                     // Go (new)
                "\\bos\\.Open\\b",                         // Go
                "\\bcontentsOfFile\\b",                    // Swift
                "\\bcontentsOf:\\b",                       // Swift
                "\\bFileManager\\b.*\\bcontents\\b",       // Swift
                "\\bopen\\s*\\(",                           // Python open()
                "\\bPath\\s*\\(.*\\.read_text\\b",         // Python pathlib
                "\\bfs\\.readFileSync\\b",                 // Node.js
                "\\bfs\\.readFile\\b",                     // Node.js
                "\\bfs\\.promises\\.readFile\\b",          // Node.js async
                "\\bfile_get_contents\\b",                 // PHP
                "\\bio\\.open\\b",                         // Lua
                "\\bFiles\\.readString\\b",                // Java
                "\\bFiles\\.readAllBytes\\b",              // Java
                "\\bBufferedReader\\b",                    // Java
                "\\breadFileAlloc\\b",                     // Zig
                "\\bstd\\.fs\\b",                          // Zig
            ]
            var hasFileRead = false
            for pattern in fileReadKeywords {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   regex.firstMatch(in: content, range: range) != nil {
                    hasFileRead = true
                    break
                }
            }
            // If has generic file read + ANY network capability → suspicious exfil wrapper
            if hasFileRead {
                let networkKeywords = [
                    // C: system/popen with network tools
                    "\\bsystem\\s*\\(", "\\bpopen\\s*\\(",
                    // Direct network tool references
                    "\\bcurl\\b", "\\bwget\\b", "\\bnc\\b", "\\bncat\\b",
                    // Go network
                    "\\bhttp\\.Post\\b", "\\bhttp\\.Get\\b", "\\bhttp\\.NewRequest\\b",
                    "\\bnet\\.Dial\\b", "\"net/http\"",
                    // Swift network
                    "\\bURLSession\\b", "\\bURLRequest\\b",
                    // Rust network
                    "\\breqwest\\b", "\\bhyper\\b", "\\bTcpStream\\b",
                    // Ruby network
                    "\\bNet::HTTP\\b", "\\bTCPSocket\\b",
                    // Perl network
                    "\\bIO::Socket\\b", "\\bLWP::", "\\bHTTP::Request\\b",
                    // Python network
                    "\\burllib\\.request\\b", "\\brequests\\.", "\\burlopen\\b",
                    // Node.js network
                    "\\bhttps?\\.request\\b", "\\bfetch\\s*\\(",
                    "require\\s*\\(\\s*['\"]https?['\"]\\s*\\)",
                    // PHP network
                    "\\bcurl_init\\b", "\\bcurl_exec\\b",
                    "\\bfile_get_contents\\s*\\(\\s*['\"]http",
                    // Lua network
                    "\\bsocket\\.http\\b",
                    // Java network
                    "\\bHttpURLConnection\\b", "\\bHttpClient\\b",
                    "\\bjava\\.net\\.",
                    // Zig network
                    "\\bstd\\.http\\.Client\\b",
                    // Generic
                    "\\bsocket\\b.*\\bconnect\\b",
                ]
                for pattern in networkKeywords {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       regex.firstMatch(in: content, range: range) != nil {
                        return "Blocked: file reads arbitrary files and has network capability (potential exfil wrapper)"
                    }
                }
            }
            return nil
        }

        // Check for network/exfil code in the content
        let networkPatterns = [
            "\\b(socket|connect|send|recv|TcpStream|UdpSocket)\\b",
            "\\b(https?|ftp)://\\S+",  // URL with scheme — anchored to require host after ://
            "\\b(urlopen|requests\\.|fetch|HttpClient|reqwest)\\b",
            "\\b(POST|PUT)\\b.*\\b(http|url|uri|endpoint)\\b",
            "\\b(curl|wget|nc|ncat)\\b",
            "\\bIO::Socket\\b",  // Perl
            "\\bNet::(HTTP|FTP)\\b",  // Ruby/Perl
            "\\bnet\\.(Dial|Listen|http)\\b",  // Go
            "\\bURLSession\\b",  // Swift
            "\\bsystem\\s*\\(.*\\b(curl|wget|nc)\\b",  // C/C++ system() with network cmd
            "\\bexec[lv]?p?\\s*\\(.*\\b(curl|wget|nc)\\b",  // C exec family
            "\\bpopen\\s*\\(.*\\b(curl|wget|nc)\\b",  // C popen
        ]
        for pattern in networkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: content, range: range) != nil {
                return "Blocked: file contains both credential access and network code (potential exfil script)"
            }
        }

        return nil
    }

    // MARK: - Temp path detection

    /// Returns true if the path is in a temp-like directory where exfil scripts get dropped.
    /// Project source files are excluded to avoid false positives from pattern string literals.
    static func isTempPath(_ path: String) -> Bool {
        GavelConstants.tempDirectoryPrefixes.contains { path.hasPrefix($0) }
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
