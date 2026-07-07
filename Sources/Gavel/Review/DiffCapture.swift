import Foundation

/// Snapshot of the changes a pending `git commit` would record, captured at
/// approval time so the reviewed bytes stay authoritative even if the tree
/// changes while the approval pends.
struct CapturedDiff {
    let diffText: String
    let commitMessage: String?
    /// True when the commit used -a/--all, so the diff is HEAD-relative
    /// (staged-only `--cached` would render empty or incomplete).
    let includesUnstaged: Bool
    let truncated: Bool
}

enum DiffCapture {

    static func capture(cwd: String, command: String) -> CapturedDiff? {
        let allFlag = commitUsesAllFlag(command)
        let diffArgs = allFlag
            ? ["diff", "HEAD", "--no-color", "--no-ext-diff"]
            : ["diff", "--cached", "--no-color", "--no-ext-diff"]
        guard let raw = runGit(diffArgs, cwd: cwd) else { return nil }

        var text = raw
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
            includesUnstaged: allFlag,
            truncated: truncated
        )
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
    static func runGit(_ args: [String], cwd: String) -> String? {
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

        guard task.terminationStatus == 0 else {
            gavelLog("[review] git \(args.first ?? "?") exited \(task.terminationStatus) cwd=\(cwd)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
