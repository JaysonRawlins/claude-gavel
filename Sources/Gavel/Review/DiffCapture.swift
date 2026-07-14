import Foundation

/// Snapshot of the changes a pending `git commit` would record, captured at
/// approval time so the reviewed bytes stay authoritative even if the tree
/// changes while the approval pends.
struct CapturedDiff {
    let diffText: String
    let commitMessage: String?
    /// True when the diff is HEAD-relative rather than staged-only: the
    /// commit used -a/--all, or the same command stages first (git add &&
    /// git commit) so nothing is staged yet at approval time.
    let includesUnstaged: Bool
    let truncated: Bool
    /// Untracked files beyond the synthesis cap — surfaced as a banner so
    /// a partial page never silently reads as the full change.
    let untrackedOmitted: Int
}

enum DiffCapture {

    /// Cap on untracked files rendered as synthesized new-file diffs.
    static let untrackedSynthesisCap = 20

    static func capture(cwd: String, command: String) -> CapturedDiff? {
        let stagesFirst = commandStagesBeforeCommit(command)
        let headRelative = commitUsesAllFlag(command) || stagesFirst
        let diffArgs = headRelative
            ? ["diff", "HEAD", "--no-color", "--no-ext-diff"]
            : ["diff", "--cached", "--no-color", "--no-ext-diff"]
        guard let raw = runGit(diffArgs, cwd: cwd) else { return nil }

        var text = raw
        var untrackedOmitted = 0
        if stagesFirst {
            // The pending `git add` will pick up untracked files that no
            // HEAD-relative diff can show — synthesize their new-file diffs.
            let untracked = (runGit(["ls-files", "--others", "--exclude-standard"], cwd: cwd) ?? "")
                .split(separator: "\n").map(String.init)
            for path in untracked.prefix(untrackedSynthesisCap) {
                // --no-index exits 1 when the files differ — that's success here.
                guard let fileDiff = runGit(
                    ["diff", "--no-color", "--no-index", "--", "/dev/null", path],
                    cwd: cwd, okStatuses: [0, 1]) else { continue }
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += fileDiff
            }
            untrackedOmitted = max(0, untracked.count - untrackedSynthesisCap)
        }

        var truncated = false
        if text.utf8.count > GavelConstants.reviewDiffMaxBytes {
            // Cut at a line boundary so the parser never sees a torn hunk line.
            let prefix = String(decoding: Array(text.utf8.prefix(GavelConstants.reviewDiffMaxBytes)), as: UTF8.self)
            text = prefix.components(separatedBy: "\n").dropLast().joined(separator: "\n")
            truncated = true
        }
        return CapturedDiff(
            diffText: text,
            commitMessage: commitMessage(from: command),
            includesUnstaged: headRelative,
            truncated: truncated,
            untrackedOmitted: untrackedOmitted
        )
    }

    /// True when the command actually invokes `git … commit` — same shell
    /// segment, quotes stripped. A bare "commit" substring shows up in grep
    /// patterns, echo text, and commit-message mentions often enough that
    /// every such command would otherwise pay a speculative git diff. The
    /// lookahead rejects config keys like `-c commit.gpgsign=false`.
    static func isGitCommit(_ command: String?) -> Bool {
        guard let command else { return false }
        let stripped = strippingQuotedSpans(command)
        return stripped.range(
            of: #"\bgit\b[^;&|\n]*\bcommit\b(?![.\w-])"#,
            options: .regularExpression) != nil
    }

    /// True when a `git add` segment precedes the commit in the same
    /// command ("git add -A && git commit …"): at approval time the add
    /// hasn't run, so the staged diff is empty and HEAD-relative capture
    /// plus untracked synthesis is the only faithful preview.
    static func commandStagesBeforeCommit(_ command: String) -> Bool {
        let stripped = strippingQuotedSpans(command)
        guard let commitRange = stripped.range(of: #"\bcommit\b"#, options: .regularExpression) else {
            return false
        }
        let head = String(stripped[..<commitRange.lowerBound])
        return head.range(of: #"\bgit\b[^;&|]*\badd\b"#, options: .regularExpression) != nil
    }

    /// Repo dir for the diff. Honors `git -C <path>` — agents routinely
    /// commit with -C because their shell cwd differs from the repo — else
    /// falls back to the hook payload's cwd. Relative -C paths resolve
    /// against that fallback.
    static func repoDir(command: String, fallback: String) -> String {
        // Git global options precede the subcommand, so only scan up to
        // "commit" — a "-C /path" inside the -m message can never match.
        let head: String
        if let commitRange = command.range(of: #"\bcommit\b"#, options: .regularExpression) {
            head = String(command[..<commitRange.lowerBound])
        } else {
            head = command
        }

        // `cd <path> && git commit` compounds: the commit runs in the cd
        // target, not the payload cwd. -C still overrides (git semantics),
        // resolving relative to the post-cd base.
        var base = fallback
        if let cd = lastCdTarget(inHead: head) {
            base = cd.hasPrefix("/") ? cd : (base as NSString).appendingPathComponent(cd)
        }

        for pattern in [#"(?:^|\s)-C[ \t]+"([^"]+)""#, #"(?:^|\s)-C[ \t]+'([^']+)'"#, #"(?:^|\s)-C[ \t]+([^\s"']+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(head.startIndex..., in: head)
            if let match = regex.firstMatch(in: head, range: range),
               let r = Range(match.range(at: 1), in: head) {
                let path = String(head[r])
                if path.hasPrefix("/") { return path }
                return (base as NSString).appendingPathComponent(path)
            }
        }
        return base
    }

    /// Last `cd <path>` among the command segments before the commit —
    /// that's the directory the commit actually runs in. Best-effort shell
    /// parsing is fine here: the review page is preview-only, so a wrong
    /// guess affects which repo is rendered, never what executes. Args with
    /// `$` are skipped (unresolvable) so the payload-cwd fallback applies.
    static func lastCdTarget(inHead head: String) -> String? {
        var target: String?
        for rawSegment in head.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
            let segment = rawSegment.trimmingCharacters(in: .whitespaces)
            guard segment.hasPrefix("cd ") || segment.hasPrefix("cd\t") else { continue }
            var arg = String(segment.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            arg = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !arg.isEmpty, arg != "-", !arg.contains("$") else { continue }
            target = (arg as NSString).expandingTildeInPath
        }
        return target
    }

    /// Detects -a/--all on the commit invocation. Quoted spans are stripped
    /// first so words inside the -m message can't read as flags.
    static func commitUsesAllFlag(_ command: String) -> Bool {
        let stripped = strippingQuotedSpans(command)
        for token in stripped.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            if token == "--all" { return true }
            if token.hasPrefix("-"), !token.hasPrefix("--"), token.dropFirst().contains("a") {
                return true
            }
        }
        return false
    }

    /// Best-effort extraction of the first -m message for the page header.
    static func commitMessage(from command: String) -> String? {
        for pattern in [#"-m[ \t]+"([^"]*)""#, #"-m[ \t]+'([^']*)'"#, #"-m[ \t]+([^\s"']+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(command.startIndex..., in: command)
            if let match = regex.firstMatch(in: command, range: range),
               let r = Range(match.range(at: 1), in: command) {
                let msg = String(command[r])
                if !msg.isEmpty { return msg }
            }
        }
        return nil
    }

    static func strippingQuotedSpans(_ text: String) -> String {
        var result = ""
        var quote: Character? = nil
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            result.append(ch)
        }
        return result
    }

    /// Runs git synchronously in `cwd` and returns stdout, or nil on failure.
    /// Absolute binary + augmented PATH: the LaunchAgent inherits a minimal
    /// PATH and git may exec helpers from /usr/local or homebrew.
    static func runGit(_ args: [String], cwd: String, okStatuses: Set<Int32> = [0]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", cwd, "--no-pager"] + args

        var environment = ProcessInfo.processInfo.environment
        let toolPaths = "/usr/local/bin:/opt/homebrew/bin"
        environment["PATH"] = toolPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        task.environment = environment

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice

        // Drain on a background thread while waiting — a diff larger than the
        // pipe buffer would otherwise deadlock waitUntilExit.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        do {
            try task.run()
        } catch {
            gavelLog("[review] git spawn failed: \(error.localizedDescription)")
            return nil
        }
        task.waitUntilExit()
        drained.wait()

        guard okStatuses.contains(task.terminationStatus) else {
            gavelLog("[review] git \(args.first ?? "?") exited \(task.terminationStatus) cwd=\(cwd)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
