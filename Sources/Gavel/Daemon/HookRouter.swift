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
            if GavelConstants.userInteractionTools.contains(payload.toolName) {
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

        // Stage 0: Taint tracking — detect multi-step exfiltration
        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName), let path = payload.filePath {
            session.taintedPaths.insert(path)
        }
        if payload.toolName == "Bash", let command = payload.command {
            if let taintReason = TaintTracker.checkExfiltration(command: command, taintedPaths: session.taintedPaths) {
                let decision = Decision(verdict: .block, reason: taintReason)
                session.blockCount += 1
                emitFeed(.decision(badge: .block, reason: taintReason, pid: session.pid, at: timestamp))
                sendResponse(decision, respond: respond)
                return
            }
            TaintTracker.recordTaints(command: command, into: &session.taintedPaths)
        }

        // Stage 0.5: Session deny rules — checked early so they block even under auto-approve
        if let rule = session.matchesSessionDeny(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath
        ) {
            session.blockCount += 1
            let reason = "Session deny: \(rule.toolName): \(rule.pattern)"
            emitFeed(.decision(badge: .block, reason: reason, pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .block, reason: reason, additionalContext: rule.explanation), respond: respond)
            return
        }

        // Stage 1: Check engine (dangerous patterns, persistent deny/allow, pause)
        let engineDecision = approvalEngine.evaluate(payload: payload, session: session)
        if engineDecision.verdict == .block {
            if engineDecision.askUser {
                // Before forcing dialog, check if a session rule already covers this.
                // Session Allow from a previous dialog should skip re-prompting.
                if let rule = session.matchesSessionRule(
                    toolName: payload.toolName,
                    command: payload.command,
                    filePath: payload.filePath
                ) {
                    session.allowCount += 1
                    emitFeed(.decision(badge: .allow, reason: "Session rule: \(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
                    sendResponse(Decision(verdict: .allow, reason: "Session rule: \(rule.pattern)"), respond: respond)
                    return
                }

                // MCP-style block: jump straight to interactive dialog
                emitFeed(.decision(badge: .block, reason: "Needs approval: \(engineDecision.reason ?? "")", pid: session.pid, at: timestamp))

                let decision = approvalCoordinator.requestApproval(
                    payload: payload, session: session, timestamp: timestamp,
                    forceDialog: true
                )
                switch decision.verdict {
                case .allow, .prompt:
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
        case .allow, .prompt:
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
