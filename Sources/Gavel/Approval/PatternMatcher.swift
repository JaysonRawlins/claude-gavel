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
            // Anchor to command position to avoid matching shell variables like
            // `DIG=$(...)` — case-insensitive matching makes `DIG` look like `dig`,
            // and the unanchored `\\b` form treated `=` as a word boundary.
            // Real `dig`/`nslookup`/`host` invocations sit at the start of a
            // command, after a chain operator, or inside a subshell, followed by
            // a whitespace-separated argument list that contains `$(`.
            ("(^|[|&;(])\\s*(dig|nslookup|host)\\s+.*\\$\\(", "Potential DNS exfiltration"),

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
            // `at` command: require a segment boundary AND a recognizable timespec.
            // The previous `\bat\b\s+` matched any prose "at " — e.g. heredoc bodies
            // inside `gh pr create`, or commit messages like "fix bug at line 42".
            // Real `at` invocations live at the start of a command or after a pipe /
            // chain operator, followed by a time keyword, clock time (`HH:MM`), or
            // relative offset (`+ N ...`).
            ("(^|[|&;])\\s*at\\s+(-[a-zA-Z]\\s+\\S+\\s+)?(now\\b|noon\\b|midnight\\b|teatime\\b|\\d{1,2}:\\d{2}|\\+\\s*\\d)", "at job scheduling"),

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
            ("\\$\\(.*\\bbase64\\s+-[dD]\\b", "Base64 decode in subshell (command obfuscation)"),
            ("\\$\\(.*\\bbase64\\b.*--decode", "Base64 decode in subshell (command obfuscation)"),
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
            ("\\.claude/gavel(/|$)", "Sensitive: Gavel config read"),
            ("\\.claude/(settings|settings\\.local)\\.json", "Sensitive: Claude Code settings read"),
            ("\\.claude/hooks(/|$)", "Sensitive: Claude Code hooks read"),
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

    }

    // MCP exfiltration patterns are now seeded as persistent rules in RuleStore.
    // See RuleStore.seededDefaults for the patterns (Slack, Playwright, Email, Webhooks, HTTP).

    /// Check if a PreToolUse payload matches any dangerous pattern.
    /// Returns a reason string if dangerous, nil if safe.
    ///
    /// MCP exfiltration patterns are handled separately as seeded persistent rules
    /// in RuleStore (visible in the Rules tab, overridable by allow rules).
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
            if let reason = checkAskUserBash(command) { return reason }
            let expanded = Self.expandInlineVariables(command)
            if expanded != command, let reason = checkAskUserBash(expanded) {
                return reason + " (variable expansion detected)"
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

        // Read/Glob/Grep: check askUser read paths (config files needed for self-mutation)
        // Grep can leak file contents via pattern matching; Glob reveals file existence.
        if ["Read", "Glob", "Grep"].contains(payload.toolName) {
            for (regex, reason) in askUserReads {
                if regex.firstMatch(in: path, range: range) != nil {
                    return reason
                }
            }
        }

        return nil
    }

    private func checkAskUserBash(_ command: String) -> String? {
        let stripped = Self.stripQuotedContent(command)
        let range = NSRange(stripped.startIndex..., in: stripped)
        for (regex, reason) in askUserBashPatterns {
            if regex.firstMatch(in: stripped, range: range) != nil {
                return reason
            }
        }
        return nil
    }

    // MARK: - Bash command matching

    private func matchBashCommand(_ command: String?) -> String? {
        guard let command = command else { return nil }

        if let reason = checkBashPatterns(command) { return reason }

        // Fallback: expand inline variables and re-check.
        // Catches: D="doppler"; S="secrets"; $D $S → doppler secrets
        let expanded = Self.expandInlineVariables(command)
        if expanded != command, let reason = checkBashPatterns(expanded) {
            return reason + " (variable expansion detected)"
        }

        return nil
    }

    private func checkBashPatterns(_ command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for (regex, reason) in bashPatterns {
            if regex.firstMatch(in: command, range: range) != nil {
                let stripped = Self.stripQuotedContent(command)
                let strippedRange = NSRange(stripped.startIndex..., in: stripped)
                if regex.firstMatch(in: stripped, range: strippedRange) != nil {
                    return reason
                }
            }
        }
        return nil
    }

    /// Strip message/string-literal content to reduce false positives.
    /// Strips heredoc content, quoted args after message flags, and echo/printf args.
    /// Does NOT strip code arguments (python -c, ruby -e, perl -e).
    ///
    ///     "git commit -m 'fixed curl issue'" → "git commit -m ''"
    ///     "echo 'curl -d foo'" → "echo ''"
    ///     "git commit -m \"$(cat <<'EOF'\ndoppler secrets\nEOF\n)\"" → heredoc content removed
    static func stripQuotedContent(_ command: String) -> String {
        var result = command

        // Strip heredoc content: <<'EOF'\n...\nEOF → <<'EOF'\nEOF
        // Heredocs are string literals (commit messages, PR bodies) — not executable.
        // Note: `bash <<EOF` (heredoc execution) is caught by a separate pattern BEFORE stripping.
        if let regex = try? NSRegularExpression(
            pattern: #"<<-?'?"?(\w+)"?'?\s*\n.*?\n\s*\1"#,
            options: [.dotMatchesLineSeparators]
        ) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<<$1\n$1")
        }

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

    // MARK: - Shell variable expansion

    /// Expand inline shell variable assignments in a command string.
    /// Catches the indirection bypass where variables hide sensitive keywords from regex matching.
    ///
    ///     "D=\"doppler\"; S=\"secrets\"; $D $S -p test"
    ///     → "D=\"doppler\"; S=\"secrets\"; doppler secrets -p test"
    ///
    /// Only expands variables assigned within the same command string (not env vars).
    /// Subshell assignments like `VAR=$(...)` are skipped (can't evaluate).
    static func expandInlineVariables(_ command: String) -> String {
        var vars: [String: String] = [:]
        let range = NSRange(command.startIndex..., in: command)

        // Match: VAR="value", VAR='value', VAR=value (with optional export/local prefix)
        let patterns: [(String, Int, Int)] = [
            (#"(?:^|[;&\s])(?:export\s+|local\s+)?([A-Za-z_]\w*)="([^"]*)""#, 1, 2),
            (#"(?:^|[;&\s])(?:export\s+|local\s+)?([A-Za-z_]\w*)='([^']*)'"#, 1, 2),
            (#"(?:^|[;&\s])(?:export\s+|local\s+)?([A-Za-z_]\w*)=([^\s;"'$][^\s;"']*)"#, 1, 2),
        ]

        for (pattern, nameGroup, valueGroup) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: command, range: range) {
                guard let nameRange = Range(match.range(at: nameGroup), in: command),
                      let valueRange = Range(match.range(at: valueGroup), in: command) else { continue }
                vars[String(command[nameRange])] = String(command[valueRange])
            }
        }

        guard !vars.isEmpty else { return command }

        // Substitute $VAR and ${VAR} references
        var result = command
        for (name, value) in vars {
            result = result.replacingOccurrences(of: "${\(name)}", with: value)
            if let regex = try? NSRegularExpression(
                pattern: "\\$\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z_0-9])"
            ) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: value)
                )
            }
        }

        return result
    }
}
