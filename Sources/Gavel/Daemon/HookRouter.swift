import Foundation

/// Central dispatch for incoming hook events — decodes, routes to approval/monitor, and (for PreToolUse) sends a verdict response.
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

    /// `respond` is non-nil only for synchronous PreToolUse — other hooks fire-and-forget.
    func handle(data: Data, respond: ((Data) -> Void)?) {
        guard let event = try? decoder.decode(HookEvent.self, from: data) else {
            handleRawHookInput(data: data, respond: respond)
            return
        }

        let session = sessionManager.session(for: event.sessionPid, agent: event.agent)
        let ts = Date(timeIntervalSince1970: event.timestamp)

        switch event.payload {
        case .preToolUse(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            if let cwd = payload.cwd { sessionManager.recordCwd(cwd, on: session) }

            // AskUserQuestion / ExitPlanMode are user-interaction tools — pass through so Claude's built-in UI handles them.
            if GavelConstants.userInteractionTools.contains(payload.toolName) {
                if let respond = respond,
                   let data = "{}".data(using: .utf8) {
                    respond(data)
                }
                return
            }

            handlePreToolUse(payload: payload, session: session, timestamp: ts, respond: respond)

        case .postToolUse(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            handlePostToolUse(payload: payload, session: session, timestamp: ts)

        case .sessionStart(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            if let cwd = payload.cwd { sessionManager.recordCwd(cwd, on: session) }

            let model = payload.model
            // Worker thread → main for the @Published write.
            DispatchQueue.main.async { session.model = model }
            let source = payload.source ?? "startup"
            emitFeed(.system("Session \(source)", pid: session.pid, at: ts))

        case .stop:
            emitFeed(.stop(pid: session.pid, at: ts))

        case .userPromptSubmit(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            let prompt = payload.prompt
            DispatchQueue.main.async { session.lastPrompt = prompt }
            let preview = (prompt ?? "").prefix(120)
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

    private func handlePreToolUse(
        payload: PreToolUsePayload,
        session: Session,
        timestamp: Date,
        respond: ((Data) -> Void)?
    ) {
        session.stats.incrementToolCall()

        // 5s activity flash for monitor row visibility. Stamp comparison protects bursts — only the most recent activity's clear fires.
        let stamp = Date()
        DispatchQueue.main.async {
            session.lastActivityAt = stamp
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if session.lastActivityAt == stamp {
                session.lastActivityAt = nil
            }
        }

        let summary = payload.command ?? payload.filePath ?? ""
        emitFeed(.toolCall(
            tool: payload.toolName,
            summary: summary,
            pid: session.pid,
            at: timestamp
        ))

        // Stage 0: Taint tracking — detect multi-step exfiltration before any allow rule can let it through.
        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName), let path = payload.filePath {
            session.taintedPaths.insert(path)
        }
        if payload.toolName == "Bash", let command = payload.command {
            if let taintReason = TaintTracker.checkExfiltration(command: command, taintedPaths: session.taintedPaths.snapshot) {
                let decision = Decision(verdict: .block, reason: taintReason)
                session.stats.incrementBlock()
                emitFeed(.decision(badge: .block, reason: taintReason, pid: session.pid, at: timestamp))
                sendResponse(decision, respond: respond)
                return
            }
            TaintTracker.recordTaints(command: command, into: session.taintedPaths)
        }

        // Stage 0.5: Session deny rules — checked early so they block even under auto-approve.
        if let rule = session.matchesSessionDeny(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath
        ) {
            session.stats.incrementBlock()
            let reason = "Session deny: \(rule.toolName): \(rule.pattern)"
            emitFeed(.decision(badge: .block, reason: reason, pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .block, reason: reason, additionalContext: rule.explanation), respond: respond)
            return
        }

        // Stage 1: Approval engine (dangerous patterns, persistent deny/allow, pause).
        let engineDecision = approvalEngine.evaluate(payload: payload, session: session)
        if engineDecision.verdict == .block {
            if engineDecision.askUser {
                if let ruleId = engineDecision.triggeringRuleId,
                   session.suppressedRuleIds.contains(ruleId) {
                    session.stats.incrementAllow()
                    emitFeed(.decision(badge: .allow, reason: "Rule suppressed for session", pid: session.pid, at: timestamp))
                    sendResponse(Decision(verdict: .allow, reason: "Rule suppressed for session"), respond: respond)
                    return
                }

                if let rule = session.matchesSessionRule(
                    toolName: payload.toolName,
                    command: payload.command,
                    filePath: payload.filePath
                ) {
                    session.stats.incrementAllow()
                    emitFeed(.decision(badge: .allow, reason: "Session rule: \(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
                    sendResponse(Decision(verdict: .allow, reason: "Session rule: \(rule.pattern)"), respond: respond)
                    return
                }

                emitFeed(.decision(badge: .block, reason: "Needs approval: \(engineDecision.reason ?? "")", pid: session.pid, at: timestamp))

                let decision = approvalCoordinator.requestApproval(
                    payload: payload, session: session, timestamp: timestamp,
                    forceDialog: true,
                    triggerReason: engineDecision.reason,
                    triggeringRuleId: engineDecision.triggeringRuleId
                )
                switch decision.verdict {
                case .allow, .prompt:
                    session.stats.incrementAllow()
                    emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
                case .block:
                    session.stats.incrementBlock()
                    emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
                }
                sendResponse(decision, respond: respond)
                return
            } else {
                session.stats.incrementBlock()
                let badge: DecisionBadge = session.isPaused ? .paused : .block
                emitFeed(.decision(badge: badge, reason: engineDecision.reason, pid: session.pid, at: timestamp))
                sendResponse(engineDecision, respond: respond)
                return
            }
        }

        if engineDecision.reason != nil {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        // Stage 2: Auto-approve and session wildcard rules — skip the dialog.
        if session.isAutoApproveActive {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .autoApprove, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        if let rule = session.matchesSessionRule(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath
        ) {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: "\(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
            sendResponse(engineDecision, respond: respond)
            return
        }

        // Stage 2.5: Sub-agent inheritance — auto-allow (deny rules already enforced in Stage 0.5/1, so blocks stand).
        if payload.isSubAgent && session.isSubAgentInheritEnabled {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .autoApprove, reason: "Sub-agent: \(payload.agentType ?? "unknown")", pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .allow, reason: "Sub-agent inherited"), respond: respond)
            return
        }

        // Stage 3: Interactive approval — blocks until user responds.
        let decision = approvalCoordinator.requestApproval(
            payload: payload,
            session: session,
            timestamp: timestamp
        )

        switch decision.verdict {
        case .allow, .prompt:
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
        case .block:
            session.stats.incrementBlock()
            emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
        }

        sendResponse(decision, respond: respond)
    }

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

    private func sendResponse(_ decision: Decision, respond: ((Data) -> Void)?) {
        // Diagnostic breadcrumb — every `[socket] enter` should have a matching `[hook] respond`. Missing one means the worker died after read but before write.
        let reasonTag = decision.reason ?? "-"
        gavelLog("[hook] respond verdict=\(decision.verdict.rawValue) reason=\(reasonTag.prefix(80))")
        if let respond = respond,
           let data = decision.hookResponse.data(using: .utf8) {
            respond(data)
        }
    }

    private func handleRawHookInput(data: Data, respond: ((Data) -> Void)?) {
        // Full HookEvent decode failed (likely large-payload truncation). Block Bash since we can't inspect the command; allow other tools.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any],
           let toolName = payload["tool_name"] as? String {
            if toolName == "Bash" {
                if let respond = respond,
                   let responseData = #"{"verdict":"block","reason":"Gavel: could not parse Bash command"}"#.data(using: .utf8) {
                    respond(responseData)
                }
                return
            }
        }

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

enum FeedEntry {
    case toolCall(tool: String, summary: String, pid: Int, at: Date)
    case decision(badge: DecisionBadge, reason: String?, pid: Int, at: Date)
    case toolResult(output: String, pid: Int, at: Date)
    case prompt(text: String, pid: Int, at: Date)
    case stop(pid: Int, at: Date)
    case system(String, pid: Int, at: Date)
}
