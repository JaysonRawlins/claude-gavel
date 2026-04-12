import Foundation

/// Routes incoming hook data to the appropriate handler.
///
/// This is the central dispatch point. Raw bytes come in from the socket,
/// get decoded, routed to the approval engine or monitor, and (for PreToolUse)
/// a response is sent back — either immediately (dangerous/auto) or after
/// user interaction via the approval panel.
final class HookRouter {
    let sessionManager: SessionManager
    let approvalEngine: ApprovalEngine
    let approvalCoordinator: ApprovalCoordinator
    var onFeedEvent: ((FeedEntry) -> Void)?

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(sessionManager: SessionManager, approvalEngine: ApprovalEngine, approvalCoordinator: ApprovalCoordinator) {
        self.sessionManager = sessionManager
        self.approvalEngine = approvalEngine
        self.approvalCoordinator = approvalCoordinator
    }

    /// Handle raw data from a socket connection.
    /// The `respond` closure is non-nil for PreToolUse (synchronous hooks).
    func handle(data: Data, respond: ((Data) -> Void)?) {
        guard let event = try? decoder.decode(HookEvent.self, from: data) else {
            handleRawHookInput(data: data, respond: respond)
            return
        }

        let session = sessionManager.session(for: event.sessionPid)
        let ts = Date(timeIntervalSince1970: event.timestamp)

        switch event.payload {
        case .preToolUse(let payload):
            if let sid = payload.sessionId { session.sessionId = sid }
            if let cwd = payload.cwd { session.cwd = cwd }

            // AskUserQuestion and ExitPlanMode are user interaction tools —
            // don't intercept, let Claude's built-in UI handle them
            if ["AskUserQuestion", "ExitPlanMode"].contains(payload.toolName) {
                if let respond = respond,
                   let data = "{}".data(using: .utf8) {
                    respond(data)
                }
                return
            }

            handlePreToolUse(payload: payload, session: session, timestamp: ts, respond: respond)

        case .postToolUse(let payload):
            if let sid = payload.sessionId { session.sessionId = sid }
            handlePostToolUse(payload: payload, session: session, timestamp: ts)

        case .sessionStart(let payload):
            if let sid = payload.sessionId { session.sessionId = sid }
            session.cwd = payload.cwd
            session.model = payload.model
            let source = payload.source ?? "startup"
            emitFeed(.system("Session \(source)", pid: session.pid, at: ts))

        case .stop:
            emitFeed(.stop(pid: session.pid, at: ts))

        case .userPromptSubmit(let payload):
            if let sid = payload.sessionId { session.sessionId = sid }
            session.lastPrompt = payload.prompt
            let preview = (payload.prompt ?? "").prefix(120)
            emitFeed(.prompt(text: String(preview), pid: session.pid, at: ts))

        case .notification(let payload):
            let msg = payload.message ?? payload.title ?? "notification"
            let kind = payload.notificationType ?? "unknown"
            emitFeed(.system("[\(kind)] \(msg)", pid: session.pid, at: ts))

        case .stopFailure(let payload):
            let errType = payload.errorType ?? "unknown"
            emitFeed(.system("Stop failure: \(errType)", pid: session.pid, at: ts))

        case .passthrough(let eventName):
            emitFeed(.system(eventName, pid: session.pid, at: ts))
        }
    }

    // MARK: - PreToolUse

    private func handlePreToolUse(
        payload: PreToolUsePayload,
        session: Session,
        timestamp: Date,
        respond: ((Data) -> Void)?
    ) {
        session.toolCallCount += 1

        let summary = payload.command ?? payload.filePath ?? ""
        emitFeed(.toolCall(
            tool: payload.toolName,
            summary: summary,
            pid: session.pid,
            at: timestamp
        ))

        // Stage 0a: Track files Claude writes (for execution taint checking)
        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName), let path = payload.filePath {
            session.taintedPaths.insert(path)
        }

        // Stage 0b: Taint tracking — check if command exfiltrates tainted data
        if payload.toolName == "Bash", let command = payload.command {
            // Check if this command sends a tainted file over the network
            if let taintReason = checkTaintedExfil(command: command, session: session) {
                let decision = Decision(verdict: .block, reason: taintReason)
                session.blockCount += 1
                emitFeed(.decision(badge: .block, reason: taintReason, pid: session.pid, at: timestamp))
                sendResponse(decision, respond: respond)
                return
            }
            // Track new taints: commands that copy sensitive data to temp paths
            trackTaint(command: command, session: session)
        }

        // Stage 1: Check engine (dangerous patterns, persistent deny/allow, pause)
        let engineDecision = approvalEngine.evaluate(payload: payload, session: session)
        if engineDecision.verdict == .block {
            if engineDecision.askUser {
                // MCP-style block: jump straight to interactive dialog
                emitFeed(.decision(badge: .block, reason: "Needs approval: \(engineDecision.reason ?? "")", pid: session.pid, at: timestamp))

                let decision = approvalCoordinator.requestApproval(
                    payload: payload, session: session, timestamp: timestamp,
                    forceDialog: true
                )
                switch decision.verdict {
                case .allow:
                    session.allowCount += 1
                    emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
                case .block:
                    session.blockCount += 1
                    emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
                }
                sendResponse(decision, respond: respond)
                return
            } else {
                // Hard block: dangerous patterns, persistent deny, pause
                session.blockCount += 1
                let badge: DecisionBadge = session.isPaused ? .paused : .block
                emitFeed(.decision(badge: badge, reason: engineDecision.reason, pid: session.pid, at: timestamp))
                sendResponse(engineDecision, respond: respond)
                return
            }
        }
        // Persistent allow rules (have a reason) skip the dialog
        if engineDecision.reason != nil {
            session.allowCount += 1
            emitFeed(.decision(badge: .allow, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        // Stage 2: Check auto-approve and session wildcard rules (skip dialog)
        if session.isAutoApproveActive {
            session.allowCount += 1
            emitFeed(.decision(badge: .autoApprove, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        if let rule = session.matchesSessionRule(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath
        ) {
            session.allowCount += 1
            emitFeed(.decision(badge: .allow, reason: "\(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        // Stage 2.5: Sub-agent inheritance — auto-approve sub-agent calls
        // (deny rules already checked in Stage 1, so blocks are respected)
        if payload.isSubAgent && session.isSubAgentInheritEnabled {
            session.allowCount += 1
            emitFeed(.decision(badge: .autoApprove, reason: "Sub-agent: \(payload.agentType ?? "unknown")", pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .allow, reason: "Sub-agent inherited"), respond: respond)
            return
        }

        // Stage 3: Interactive approval (blocks until user responds)
        let decision = approvalCoordinator.requestApproval(
            payload: payload,
            session: session,
            timestamp: timestamp
        )

        switch decision.verdict {
        case .allow:
            session.allowCount += 1
            emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
        case .block:
            session.blockCount += 1
            emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
        }

        sendResponse(decision, respond: respond)
    }

    // MARK: - PostToolUse

    private func handlePostToolUse(
        payload: PostToolUsePayload,
        session: Session,
        timestamp: Date
    ) {
        var output = ""
        if let response = payload.toolResponse {
            if let str = response.stringValue {
                output = str
            } else if let dict = response.dictValue {
                let stdout = dict["stdout"]?.stringValue ?? ""
                let stderr = dict["stderr"]?.stringValue ?? ""
                output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }

        if !output.isEmpty {
            emitFeed(.toolResult(output: output, pid: session.pid, at: timestamp))
        }
    }

    // MARK: - Taint Tracking

    /// Sensitive path patterns that, when read/copied, taint the destination.
    private static let sensitiveSources = [
        "\\.ssh/", "\\.gnupg/", "\\.aws/", "\\.kube/config",
        "\\.env$", "\\.npmrc$", "\\.netrc$", "\\.docker/config",
    ]

    /// Network commands that could exfiltrate tainted data.
    private static let networkCommands = [
        "\\bcurl\\b", "\\bwget\\b", "\\bscp\\b", "\\brsync\\b",
        "\\bpython3?\\b.*\\b(urlopen|requests|socket)",
        "\\bnc\\b", "\\bncat\\b", "\\bopenssl\\b.*s_client",
    ]

    /// Check if a command references any tainted file in a dangerous context.
    private func checkTaintedExfil(command: String, session: Session) -> String? {
        guard !session.taintedPaths.isEmpty else { return nil }

        for taintedPath in session.taintedPaths {
            guard command.contains(taintedPath) else { continue }

            // Check if tainted file is being sent over network
            for pattern in Self.networkCommands {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                    return "Taint detected: \(taintedPath) contains sensitive data and is being sent over network"
                }
            }

            // Check if tainted file is being executed directly (compiled binary from Claude-written source)
            // Match: /path/to/binary at start of command, after &&, after ;, or after |
            let execPatterns = [
                "^\\s*\(NSRegularExpression.escapedPattern(for: taintedPath))\\b",
                "&&\\s*\(NSRegularExpression.escapedPattern(for: taintedPath))\\b",
                ";\\s*\(NSRegularExpression.escapedPattern(for: taintedPath))\\b",
                "\\|\\s*\(NSRegularExpression.escapedPattern(for: taintedPath))\\b",
            ]
            for pattern in execPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                    return "Taint detected: executing Claude-compiled binary \(taintedPath)"
                }
            }
        }
        return nil
    }

    /// Track commands that copy sensitive data to temp/intermediate files.
    /// e.g., "cat ~/.ssh/id_rsa > /tmp/key.txt" taints /tmp/key.txt
    private func trackTaint(command: String, session: Session) {
        // Check if any sensitive source is referenced
        var hasSensitiveSource = false
        for pattern in Self.sensitiveSources {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                hasSensitiveSource = true
                break
            }
        }
        guard hasSensitiveSource else { return }

        // Look for output redirection to a file: > /path or > relative_path or >> /path
        if let redirectRegex = try? NSRegularExpression(pattern: #">>?\s*(\S+)"#),
           let match = redirectRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
            let pathRange = Range(match.range(at: 1), in: command)!
            let taintedPath = String(command[pathRange])
            session.taintedPaths.insert(taintedPath)
        }

        // Look for compile outputs: gcc -o /path/binary, go build -o /path/binary, etc.
        if let outputRegex = try? NSRegularExpression(pattern: #"\b(gcc|g\+\+|clang|rustc|swiftc|javac)\b.*-o\s+(\S+)"#),
           let match = outputRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
            let pathRange = Range(match.range(at: 2), in: command)!
            session.taintedPaths.insert(String(command[pathRange]))
        }
        if let goOutputRegex = try? NSRegularExpression(pattern: #"\bgo\s+build\b.*-o\s+(\S+)"#),
           let match = goOutputRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
            let pathRange = Range(match.range(at: 1), in: command)!
            session.taintedPaths.insert(String(command[pathRange]))
        }

        // Look for cp/mv destination: cp source dest
        if let cpRegex = try? NSRegularExpression(pattern: #"\b(cp|mv)\b\s+\S+\s+(/\S+)"#),
           let match = cpRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
            let pathRange = Range(match.range(at: 2), in: command)!
            let taintedPath = String(command[pathRange])
            session.taintedPaths.insert(taintedPath)
        }
    }

    // MARK: - Helpers

    private func sendResponse(_ decision: Decision, respond: ((Data) -> Void)?) {
        if let respond = respond,
           let data = decision.hookResponse.data(using: .utf8) {
            respond(data)
        }
    }

    private func handleRawHookInput(data: Data, respond: ((Data) -> Void)?) {
        // Try to extract at least the tool name to make a basic decision
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any],
           let toolName = payload["tool_name"] as? String {
            // Got tool name but full decode failed (likely large payload truncation)
            // Allow non-Bash tools, block Bash (since we can't inspect the command)
            if toolName == "Bash" {
                if let respond = respond,
                   let responseData = #"{"verdict":"block","reason":"Gavel: could not parse Bash command"}"#.data(using: .utf8) {
                    respond(responseData)
                }
                return
            }
        }
        // Non-Bash or completely unparseable — allow to avoid blocking legitimate writes
        if let respond = respond,
           let responseData = #"{"verdict":"allow"}"#.data(using: .utf8) {
            respond(responseData)
        }
    }

    private func emitFeed(_ entry: FeedEntry) {
        DispatchQueue.main.async { [weak self] in
            self?.onFeedEvent?(entry)
        }
    }
}

// MARK: - Feed Entries

enum FeedEntry {
    case toolCall(tool: String, summary: String, pid: Int, at: Date)
    case decision(badge: DecisionBadge, reason: String?, pid: Int, at: Date)
    case toolResult(output: String, pid: Int, at: Date)
    case prompt(text: String, pid: Int, at: Date)
    case stop(pid: Int, at: Date)
    case system(String, pid: Int, at: Date)
}
