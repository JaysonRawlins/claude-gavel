import Foundation

/// Matches tool calls against dangerous bash commands and sensitive file paths.
struct PatternMatcher {
    private let bashPatterns: [(regex: NSRegularExpression, reason: String)]

    private let askUserBashPatterns: [(regex: NSRegularExpression, reason: String)]

    private let protectedPaths: [(regex: NSRegularExpression, reason: String)]

    private let askUserPaths: [(regex: NSRegularExpression, reason: String)]

    private let sensitiveReads: [(regex: NSRegularExpression, reason: String)]

    private let askUserReads: [(regex: NSRegularExpression, reason: String)]

    init() {
        let rawBash: [(pattern: String, reason: String)] = [
            // `(?-i:...)` keeps short flags case-sensitive — curl's `-D`/`-f`/`-t` (download/fail/telnet) must not match the `.caseInsensitive`-compiled rule set.
            ("\\bcurl\\b.*(?-i:-d|--data|--data-raw|--data-binary|--data-urlencode|-F|--form|--upload-file|-T)\\b", "Potential data exfiltration via curl"),
            // Anchored to command position so env-var assignments like `MY_CURL=$(...)` don't false-trigger under case-insensitive matching.
            ("(^|[|&;(])\\s*curl\\s+.*\\$\\(", "Potential exfiltration via curl with command substitution"),
            ("\\bwget\\b.*--post-(data|file)", "Potential data exfiltration via wget"),
            ("\\b(python3?|ruby|perl)\\b.*\\b(urlopen|urllib|requests\\.|Net::HTTP|socket\\.connect|TCPSocket|IO\\.popen)", "Scripting language network exfiltration"),
            ("\\bopenssl\\b.*s_client.*connect", "Potential exfiltration via openssl"),
            // Anchored: `SCP=...` env-var prefix would otherwise match `\bSCP\b` under case-insensitive matching.
            ("(^|[|&;(])\\s*(scp|rsync)\\s+.*:", "Potential file exfiltration via scp/rsync"),
            // Anchored: `DIG=$(...)` env-var prefix would otherwise match `\bDIG\b` under case-insensitive matching.
            ("(^|[|&;(])\\s*(dig|nslookup|host)\\s+.*\\$\\(", "Potential DNS exfiltration"),

            // Anchored: `ENV=prod node ...` env-var prefix is common in shell pipelines and would otherwise false-block.
            ("(^|[|&;(])\\s*(env|printenv|set)\\s+.*[|].*\\b(curl|wget|nc|ncat|python|ruby|perl)\\b", "Piping environment to network command"),
            ("(^|[|&;(])\\s*(env|printenv|set)\\s+.*>\\s*/tmp/", "Environment variables written to temp file"),
            // `(?-i:-d)` must stay case-sensitive — see curl-data rationale above.
            ("\\bcurl\\b.*(?-i:-d).*\\$\\(\\s*(env|printenv|set)\\b", "Environment exfiltration via curl subshell"),

            ("\\bbash\\s+-i\\s+>&", "Reverse shell pattern detected"),
            ("/dev/tcp/", "Reverse shell via /dev/tcp"),
            ("\\b(nc|ncat)\\b.*(-e|--exec|--sh-exec)\\s+/", "Netcat reverse shell"),
            ("\\b(python3?|ruby|perl)\\b.*socket.*connect.*\\b(exec|spawn|system|dup2)\\b", "Scripting reverse shell"),
            ("\\bsocat\\b.*exec.*tcp", "Socat reverse shell"),
            ("\\bzsh\\s+-i\\s+>&", "Zsh reverse shell"),
            ("\\bphp\\b.*fsockopen.*exec", "PHP reverse shell"),

            // Anchored + `\s` follower: `CRONTAB=...` env-var assignment has `=` after the name (not whitespace), so it can't false-match.
            ("(^|[|&;(])\\s*crontab(\\s+|$)", "Crontab modification"),
            ("\\blaunchctl\\b\\s+(load|unload|submit|bootstrap|bootout|enable|disable|kickstart)", "LaunchAgent/Daemon modification"),
            // Anchored + requires a real timespec — bare "at " in prose (commit messages, heredocs) would otherwise match.
            ("(^|[|&;])\\s*at\\s+(-[a-zA-Z]\\s+\\S+\\s+)?(now\\b|noon\\b|midnight\\b|teatime\\b|\\d{1,2}:\\d{2}|\\+\\s*\\d)", "at job scheduling"),

            ("\\bmkfs\\b", "Filesystem format command"),
            ("\\bdd\\b\\s+.*of=/dev/", "Direct disk write"),

            ("\\b(cat|head|tail|less|more|cp|mv|base64|xxd|openssl)\\b.*\\.ssh/(id_|authorized|known_hosts)", "SSH key/config access"),
            ("\\b(cat|head|tail|less|more|cp|mv|base64)\\b.*\\.gnupg/", "GPG key access"),

            ("\\b(pkill|killall)\\b.*\\bgav", "Attempt to kill Gavel daemon"),
            ("\\bkill\\b.*\\b(pgrep|pidof)\\b.*gav", "Attempt to kill Gavel daemon"),
            ("\\brm\\b.*gavel\\.sock", "Attempt to remove Gavel socket"),
            ("\\brm\\b.*\\.claude/gavel/", "Attempt to delete Gavel config"),

            ("\\bkill\\b.*\\$\\(.*gav", "Attempt to kill Gavel via PID lookup"),

            ("\\beval\\b.*\\$\\(.*\\b(base64|b64decode)\\b", "Obfuscated command via eval+base64"),
            ("\\bbase64\\s+-[dD]\\b.*\\|.*\\b(bash|sh|zsh)\\b", "Base64 decoded pipe to shell"),
            ("\\$\\(.*\\bbase64\\s+-[dD]\\b", "Base64 decode in subshell (command obfuscation)"),
            ("\\$\\(.*\\bbase64\\b.*--decode", "Base64 decode in subshell (command obfuscation)"),
            ("\\bbash\\s*<<", "Heredoc execution (potential obfuscation)"),

            ("\\b(gcc|g\\+\\+|clang|clang\\+\\+|rustc|javac|swiftc)\\b.*/tmp/", "Compiling code in temp directory"),
            ("\\b(go\\s+build|go\\s+run)\\b.*/tmp/", "Building/running Go code from temp directory"),
            ("\\bcargo\\s+(build|run)\\b.*--manifest-path.*/tmp/", "Building Rust code from temp directory"),

            ("\\b(perl|ruby|node|swift|php|lua)\\b\\s+/tmp/", "Running script from temp directory"),

            ("^\\s*/tmp/\\S+", "Running executable from temp directory"),
            ("&&\\s*/tmp/\\S+", "Running executable from temp directory (chained)"),
            ("\\|\\s*/tmp/\\S+", "Running executable from temp directory (piped)"),
            (";\\s*/tmp/\\S+", "Running executable from temp directory (sequential)"),

            ("\\bcd\\s+/tmp\\b.*&&", "Changing to temp directory and executing"),

            ("\\bchmod\\b.*\\+x.*/tmp/", "Making temp file executable"),
        ]

        let rawAskUserBash: [(pattern: String, reason: String)] = [
            ("\\brm\\s+-\\w*[rR]\\w*\\s+/(?!tmp\\b)", "Recursive delete from root path"),
            ("\\brm\\s+-\\w*[rR]\\w*\\s+\\./", "Recursive delete from current directory"),
            ("\\brm\\s+-\\w*[rR]\\w*\\s+\\.\\./", "Recursive delete from parent directory"),
            ("\\brm\\s+--recursive", "Recursive delete (long flag)"),
            ("\\baz\\s+.*\\b(update|create|delete|set|add|remove|start|stop|restart)\\b", "Azure CLI write operation"),
            ("\\baws\\s+.*\\b(create|delete|update|put|remove|terminate|stop|start|modify|run)\\b(?!.*--dry-run)", "AWS CLI write operation"),
            ("\\bgcloud\\s+.*\\b(create|delete|update|add|remove|start|stop|deploy)\\b", "GCloud CLI write operation"),
            // Broad fallbacks for the anchored hard-block patterns above — catches `bash -c "curl $(...)"` style where the command isn't at command position.
            ("\\bcurl\\b.*\\$\\(", "curl with command substitution (broad — review)"),
            ("\\bcrontab\\b", "crontab reference (broad — review)"),
        ]

        let rawPaths: [(pattern: String, reason: String)] = [
            ("\\.ssh/(id_|authorized_keys|config)", "Protected: SSH keys/config"),
            ("\\.gnupg/", "Protected: GPG keys"),
            ("LaunchAgents/", "Protected: LaunchAgent (persistence risk)"),
            ("LaunchDaemons/", "Protected: LaunchDaemon (persistence risk)"),
            ("\\.aws/(credentials|config)", "Protected: AWS credentials"),
            ("\\.kube/config", "Protected: Kubernetes config"),
            ("\\.env$", "Protected: Environment file"),
        ]

        let rawAskUserPaths: [(pattern: String, reason: String)] = [
            ("\\.claude/gavel/(rules\\.json|session-defaults\\.json|hooks/|bin/)", "Sensitive: Gavel config"),
            ("\\.claude/(settings\\.json|settings\\.local\\.json|hooks/)", "Sensitive: Claude Code settings/hooks"),
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

        let rawSensitiveReads: [(pattern: String, reason: String)] = [
            ("\\.ssh/(id_|id_rsa|id_ed25519|id_ecdsa)", "Blocked: SSH private key read"),
            ("\\.gnupg/(private-keys|secring|trustdb)", "Blocked: GPG private key read"),
            ("\\.aws/credentials", "Blocked: AWS credentials read"),
            ("\\.kube/config", "Blocked: Kubernetes config read"),
            ("\\.env$", "Blocked: Environment file read"),
            ("\\.env\\.local$", "Blocked: Local environment file read"),
            ("Keychains/", "Blocked: Keychain access"),
            ("\\.(token|secret|credentials|key)$", "Blocked: Credential file read"),
            ("\\.npmrc$", "Blocked: NPM config (may contain tokens)"),
            ("\\.docker/config\\.json", "Blocked: Docker config (may contain tokens)"),
            ("\\.netrc$", "Blocked: netrc credentials"),
        ]

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

    func matchDangerous(payload: PreToolUsePayload) -> String? {
        switch payload.toolName {
        case "Bash":
            return matchBashCommand(payload.command)
        case "Write", "Edit", "MultiEdit":
            if let pathBlock = matchProtectedPath(payload.filePath) {
                return pathBlock
            }

            if let path = payload.filePath, Self.isTempPath(path), !Self.isDocumentationPath(path) {
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

    func matchSensitivePath(payload: PreToolUsePayload) -> String? {
        if payload.toolName == "Bash", let command = payload.command {
            if let reason = checkAskUserBash(command) { return reason }
            let expanded = Self.expandInlineVariables(command)
            if expanded != command, let reason = checkAskUserBash(expanded) {
                return reason + " (variable expansion detected)"
            }
        }

        guard let path = payload.filePath else { return nil }
        let range = NSRange(path.startIndex..., in: path)

        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName) {
            for (regex, reason) in askUserPaths {
                if regex.firstMatch(in: path, range: range) != nil {
                    return reason
                }
            }
        }

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

    private func matchBashCommand(_ command: String?) -> String? {
        guard let command = command else { return nil }

        if let reason = checkBashPatterns(command) { return reason }

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

    /// Strip heredoc bodies and `-m`/`--message`/`echo`/`printf` quoted args so prose can't trigger command pattern matches.
    static func stripQuotedContent(_ command: String) -> String {
        var result = command

        if let regex = try? NSRegularExpression(
            pattern: #"<<-?'?"?(\w+)"?'?\s*\n.*?\n\s*\1"#,
            options: [.dotMatchesLineSeparators]
        ) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<<$1\n$1")
        }

        if let regex = try? NSRegularExpression(pattern: #"(-m|--message|--body|--title)\s+"([^"\\]|\\.)*""#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \"\"")
        }
        if let regex = try? NSRegularExpression(pattern: #"(-m|--message|--body|--title)\s+'[^']*'"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ''")
        }

        if let regex = try? NSRegularExpression(pattern: #"\b(echo|printf)\s+"([^"\\]|\\.)*""#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 \"\"")
        }
        if let regex = try? NSRegularExpression(pattern: #"\b(echo|printf)\s+'[^']*'"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ''")
        }

        return result
    }

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

    private func matchDangerousContent(_ content: String?) -> String? {
        guard let content = content, content.count > GavelConstants.minContentScanLength else { return nil }

        let range = NSRange(content.startIndex..., in: content)

        // Path-shaped indicators only — bare nouns like "credentials" trigger FPs in docs that mention auth.
        let credPatterns = [
            "\\.ssh/", "\\.aws/", "\\.gnupg/", "\\.env\\b",
            "\\.kube/config", "\\.npmrc", "\\.netrc", "\\.docker/config",
            "id_rsa", "id_ed25519", "authorized_keys",
        ]
        var hasCredRef = false
        for pattern in credPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: content, range: range) != nil {
                hasCredRef = true
                break
            }
        }

        // No path-shaped credential reference — fall back to the generic "reads arbitrary file + has network capability" exfil-wrapper heuristic.
        if !hasCredRef {
            let fileReadKeywords = [
                "\\bfopen\\b", "\\bfread\\b",
                "\\bopen\\b.*O_RDONLY",
                "\\bfs::read\\b", "\\bfs::read_to_string",
                "\\bFile\\.read\\b",
                "\\bioutil\\.ReadFile\\b",
                "\\bos\\.ReadFile\\b",
                "\\bos\\.Open\\b",
                "\\bcontentsOfFile\\b",
                "\\bcontentsOf:\\b",
                "\\bFileManager\\b.*\\bcontents\\b",
                "\\bopen\\s*\\(",
                "\\bPath\\s*\\(.*\\.read_text\\b",
                "\\bfs\\.readFileSync\\b",
                "\\bfs\\.readFile\\b",
                "\\bfs\\.promises\\.readFile\\b",
                "\\bfile_get_contents\\b",
                "\\bio\\.open\\b",
                "\\bFiles\\.readString\\b",
                "\\bFiles\\.readAllBytes\\b",
                "\\bBufferedReader\\b",
                "\\breadFileAlloc\\b",
                "\\bstd\\.fs\\b",
            ]
            var hasFileRead = false
            for pattern in fileReadKeywords {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   regex.firstMatch(in: content, range: range) != nil {
                    hasFileRead = true
                    break
                }
            }

            if hasFileRead {
                let networkKeywords = [
                    "\\bsystem\\s*\\(", "\\bpopen\\s*\\(",
                    "\\bcurl\\b", "\\bwget\\b", "\\bnc\\b", "\\bncat\\b",
                    "\\bhttp\\.Post\\b", "\\bhttp\\.Get\\b", "\\bhttp\\.NewRequest\\b",
                    "\\bnet\\.Dial\\b", "\"net/http\"",
                    "\\bURLSession\\b", "\\bURLRequest\\b",
                    "\\breqwest\\b", "\\bhyper\\b", "\\bTcpStream\\b",
                    "\\bNet::HTTP\\b", "\\bTCPSocket\\b",
                    "\\bIO::Socket\\b", "\\bLWP::", "\\bHTTP::Request\\b",
                    "\\burllib\\.request\\b", "\\brequests\\.", "\\burlopen\\b",
                    "\\bhttps?\\.request\\b", "\\bfetch\\s*\\(",
                    "require\\s*\\(\\s*['\"]https?['\"]\\s*\\)",
                    "\\bcurl_init\\b", "\\bcurl_exec\\b",
                    "\\bfile_get_contents\\s*\\(\\s*['\"]http",
                    "\\bsocket\\.http\\b",
                    "\\bHttpURLConnection\\b", "\\bHttpClient\\b",
                    "\\bjava\\.net\\.",
                    "\\bstd\\.http\\.Client\\b",
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

        let networkPatterns = [
            "\\b(socket|connect|send|recv|TcpStream|UdpSocket)\\b",
            "\\b(https?|ftp)://\\S+",
            "\\b(urlopen|requests\\.|fetch|HttpClient|reqwest)\\b",
            "\\b(POST|PUT)\\b.*\\b(http|url|uri|endpoint)\\b",
            "\\b(curl|wget|nc|ncat)\\b",
            "\\bIO::Socket\\b",
            "\\bNet::(HTTP|FTP)\\b",
            "\\bnet\\.(Dial|Listen|http)\\b",
            "\\bURLSession\\b",
            "\\bsystem\\s*\\(.*\\b(curl|wget|nc)\\b",
            "\\bexec[lv]?p?\\s*\\(.*\\b(curl|wget|nc)\\b",
            "\\bpopen\\s*\\(.*\\b(curl|wget|nc)\\b",
        ]
        for pattern in networkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: content, range: range) != nil {
                return "Blocked: file contains both credential access and network code (potential exfil script)"
            }
        }

        return nil
    }

    /// True if `path` lives in a temp-like prefix where dropped exfil scripts get scanned (project source is excluded to avoid pattern-literal FPs).
    static func isTempPath(_ path: String) -> Bool {
        GavelConstants.tempDirectoryPrefixes.contains { path.hasPrefix($0) }
    }

    /// True for prose files (md/txt/html/etc) — excluded from exfil content scanning so docs mentioning auth + hyperlinks don't false-block.
    static func isDocumentationPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let docExtensions = [".md", ".mdx", ".markdown", ".txt", ".rst", ".adoc", ".asciidoc", ".html", ".htm"]
        return docExtensions.contains { lower.hasSuffix($0) }
    }

    /// Expand inline shell variable assignments (`D="doppler"; $D ...` → `doppler ...`) so indirection can't hide sensitive keywords from regex matching.
    static func expandInlineVariables(_ command: String) -> String {
        var vars: [String: String] = [:]
        let range = NSRange(command.startIndex..., in: command)

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
