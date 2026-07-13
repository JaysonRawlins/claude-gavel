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
    /// Pending rule-proposal inbox (set at wiring time; nil in tests that don't exercise proposals).
    var proposalStore: ProposalStore?

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

        let session = sessionManager.session(for: event.sessionPid, agent: event.agent)
        let ts = Date(timeIntervalSince1970: event.timestamp)

        switch event.payload {
        case .preToolUse(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            // Sub-agent payloads can report an isolated worktree as cwd; the
            // session row, transcript watcher, and review links must keep
            // tracking the main conversation's directory.
            if let cwd = payload.cwd, !payload.isSubAgent { sessionManager.recordCwd(cwd, on: session) }

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
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            handlePostToolUse(payload: payload, session: session, timestamp: ts)

        case .sessionStart(let payload):
            if let sid = payload.sessionId { sessionManager.recordSessionId(sid, on: session) }
            if let cwd = payload.cwd { sessionManager.recordCwd(cwd, on: session) }
            if let name = payload.sessionName {
                sessionManager.updateLabel(name, on: session, sessionId: payload.sessionId)
            }
            // Worker thread → main for the @Published write.
            let model = payload.model
            DispatchQueue.main.async { session.model = model }
            let source = payload.source ?? "startup"
            emitFeed(.system("Session \(source)", pid: session.pid, at: ts))
            if payload.requestRemoteApproval == true {
                requestRemoteApprovalToggle(session: session, timestamp: ts)
            }

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

        case .proposeRule(let payload):
            handleProposeRule(payload: payload, session: session, timestamp: ts, respond: respond)

        case .passthrough(let eventName):
            emitFeed(.system(eventName, pid: session.pid, at: ts))
        }
    }

    // MARK: - ProposeRule

    /// Queue a tighten-only rule proposal for user review. Always responds
    /// (the propose-rule CLI waits for the ack) — either a queued id or a
    /// rejection reason Claude can act on.
    private func handleProposeRule(
        payload: ProposeRulePayload,
        session: Session,
        timestamp: Date,
        respond: ((Data) -> Void)?
    ) {
        let result: ProposalStore.SubmitResult
        if let store = proposalStore {
            result = store.submit(
                toolName: payload.toolName ?? "",
                pattern: payload.pattern ?? "",
                isRegex: payload.isRegex ?? true,
                verdict: payload.verdict ?? "",
                reason: payload.reason ?? "",
                example: payload.example,
                sessionPid: session.pid,
                sessionId: payload.sessionId
            )
        } else {
            result = .rejected("Proposal inbox unavailable")
        }

        let response: [String: Any]
        switch result {
        case .queued(let id):
            let summary = "\(payload.toolName ?? "?"): \(payload.pattern ?? "?") (\(payload.verdict ?? "?"))"
            emitFeed(.system("⚑ Claude proposed rule: \(summary) — pending review in Rules tab", pid: session.pid, at: timestamp))
            GavelNotifications.notify(
                title: "Gavel — Rule Proposed",
                body: "\(summary)\n\(payload.reason ?? "")",
                sound: false
            )
            response = ["status": "queued", "id": id.uuidString,
                        "message": "Proposal queued for user review in the Gavel Monitor"]
        case .rejected(let reason):
            emitFeed(.system("⚑ Rule proposal rejected: \(reason)", pid: session.pid, at: timestamp))
            response = ["status": "rejected", "reason": reason]
        }

        if let respond = respond,
           let data = try? JSONSerialization.data(withJSONObject: response) {
            respond(data)
        }
    }

    // MARK: - PreToolUse

    private func handlePreToolUse(
        payload: PreToolUsePayload,
        session: Session,
        timestamp: Date,
        respond: ((Data) -> Void)?
    ) {
        session.stats.incrementToolCall()

        // Flash the row in the monitor so the user can see which session is
        // working without reading PIDs. Auto-clears after 5s; SwiftUI animates
        // the fade. Stamp comparison protects against bursts — only the most
        // recent activity's clear actually fires (so a burst extends the visible
        // window rather than truncating it). 5s is the sweet spot at ~12+
        // sessions: long enough that human glance-and-find can't miss it, short
        // enough that it doesn't pile up across rows during normal traffic.
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

        if payload.toolName == "Skill", let skill = payload.skill, !skill.isEmpty {
            if session.tags.addObserved("skill:\(skill)", at: timestamp) {
                sessionManager.saveActiveSessions()
            }
        }

        // Stage 0: Taint tracking — detect multi-step exfiltration
        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName), let path = payload.filePath {
            session.taintedPaths.insert(path)
        }
        if payload.toolName == "Bash", let command = payload.command {
            if let taintReason = TaintTracker.checkExfiltration(command: command, taintedPaths: session.taintedPaths.snapshot) {
                let decision = Decision(verdict: .block, reason: taintReason)
                session.stats.incrementBlock()
                emitFeed(.decision(badge: .block, reason: taintReason, pid: session.pid, at: timestamp))
                sendResponse(decision, payload: payload, session: session, respond: respond)
                return
            }
            TaintTracker.recordTaints(command: command, into: session.taintedPaths)
        }

        // Stage 0.5: Session deny rules — checked early so they block even under auto-approve
        if let rule = session.matchesSessionDeny(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath,
            toolInput: payload.toolInput
        ) {
            session.stats.incrementBlock()
            let reason = "Session deny: \(rule.toolName): \(rule.pattern)"
            emitFeed(.decision(badge: .block, reason: reason, pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .block, reason: reason, additionalContext: rule.explanation), payload: payload, session: session, respond: respond)
            return
        }

        let engineDecision = approvalEngine.evaluate(payload: payload, session: session)
        if engineDecision.verdict == .block {
            if engineDecision.askUser {
                // Unconditional prompts (guardrail-mutation writes) can't be short-circuited by a
                // session-allow or a suppressed rule — they always reach the dialog, Allow-once only.
                if !engineDecision.nonSuppressible {
                    // Rule suppressed for session — covers the rule's full regex scope.
                    if let ruleId = engineDecision.triggeringRuleId,
                       session.suppressedRuleIds.contains(ruleId) {
                        session.stats.incrementAllow()
                        emitFeed(.decision(badge: .allow, reason: "Rule suppressed for session", pid: session.pid, at: timestamp))
                        sendResponse(Decision(verdict: .allow, reason: "Rule suppressed for session"), payload: payload, session: session, respond: respond)
                        return
                    }

                    // Before forcing dialog, check if a session rule already covers this.
                    // Session Allow from a previous dialog should skip re-prompting.
                    if let rule = session.matchesSessionRule(
                        toolName: payload.toolName,
                        command: payload.command,
                        filePath: payload.filePath,
                        toolInput: payload.toolInput
                    ) {
                        session.stats.incrementAllow()
                        emitFeed(.decision(badge: .allow, reason: "Session rule: \(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
                        sendResponse(Decision(verdict: .allow, reason: "Session rule: \(rule.pattern)"), payload: payload, session: session, respond: respond)
                        return
                    }

                    // Browsing lease: site-scoped session allow for chrome
                    // page-interaction tools + same-site navigation. Drift
                    // revocation lives in handlePostToolUse.
                    if let lease = session.browsingLease,
                       let reason = lease.allows(
                           toolName: payload.toolName,
                           url: payload.toolInput["url"]?.stringValue
                       ) {
                        session.stats.incrementAllow()
                        emitFeed(.decision(badge: .allow, reason: reason, pid: session.pid, at: timestamp))
                        sendResponse(Decision(verdict: .allow, reason: reason), payload: payload, session: session, respond: respond)
                        return
                    }
                }

                // MCP-style block: jump straight to interactive dialog
                emitFeed(.decision(badge: .block, reason: "Needs approval: \(engineDecision.reason ?? "")", pid: session.pid, at: timestamp))

                let decision = approvalCoordinator.requestApproval(
                    payload: payload, session: session, timestamp: timestamp,
                    forceDialog: true,
                    triggerReason: engineDecision.reason,
                    triggeringRuleId: engineDecision.triggeringRuleId,
                    nonSuppressible: engineDecision.nonSuppressible
                )
                switch decision.verdict {
                case .allow, .prompt:
                    session.stats.incrementAllow()
                    emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
                case .block:
                    session.stats.incrementBlock()
                    emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
                }
                sendResponse(decision, payload: payload, session: session, respond: respond)
                return
            } else {
                // Hard block: dangerous patterns, persistent deny, pause
                session.stats.incrementBlock()
                let badge: DecisionBadge = session.isPaused ? .paused : .block
                emitFeed(.decision(badge: badge, reason: engineDecision.reason, pid: session.pid, at: timestamp))
                sendResponse(engineDecision, payload: payload, session: session, respond: respond)
                return
            }
        }
        if engineDecision.reason != nil {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, payload: payload, session: session, respond: respond)
            return
        }

        // Stage 2: Check auto-approve and session wildcard rules (skip dialog)
        if session.isAutoApproveActive {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .autoApprove, reason: engineDecision.reason, pid: session.pid, at: timestamp))
            sendResponse(engineDecision, payload: payload, session: session, respond: respond)
            return
        }

        if let rule = session.matchesSessionRule(
            toolName: payload.toolName,
            command: payload.command,
            filePath: payload.filePath,
            toolInput: payload.toolInput
        ) {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: "\(rule.toolName): \(rule.pattern)", pid: session.pid, at: timestamp))
            sendResponse(engineDecision, payload: payload, session: session, respond: respond)
            return
        }

        // Stage 2.5: Sub-agent inheritance — auto-approve sub-agent calls
        // (deny rules already checked in Stage 1, so blocks are respected)
        if payload.isSubAgent && session.isSubAgentInheritEnabled {
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .autoApprove, reason: "Sub-agent: \(payload.agentType ?? "unknown")", pid: session.pid, at: timestamp))
            sendResponse(Decision(verdict: .allow, reason: "Sub-agent inherited"), payload: payload, session: session, respond: respond)
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
            session.stats.incrementAllow()
            emitFeed(.decision(badge: .allow, reason: decision.reason, pid: session.pid, at: timestamp))
        case .block:
            session.stats.incrementBlock()
            emitFeed(.decision(badge: .block, reason: decision.reason, pid: session.pid, at: timestamp))
        }

        sendResponse(decision, payload: payload, session: session, respond: respond)
    }

    // MARK: - PostToolUse

    private func handlePostToolUse(
        payload: PostToolUsePayload,
        session: Session,
        timestamp: Date
    ) {
        var output = ""
        if let response = payload.toolResponse {
            output = Self.extractResponseText(response)
        }

        // Browsing-lease drift check: the extension appends a Tab Context
        // block (with the executed tab's live URL) to every chrome tool
        // result, so an in-page navigation is visible in the response of the
        // click that caused it. Any off-domain URL — or an unparseable
        // response, fail closed — revokes the lease before the next call.
        if BrowsingLease.driftCheckedTools.contains(payload.toolName),
           let lease = session.browsingLease {
            if !lease.isActive {
                session.revokeBrowsingLease()
                gavelLog("[lease] expired pid=\(session.pid) domain=\(lease.domain)")
            } else if let why = BrowsingLease.driftReason(inResponse: output, domain: lease.domain) {
                session.revokeBrowsingLease()
                let reason = "Browsing lease revoked (\(lease.domain)): \(why)"
                gavelLog("[lease] \(reason) pid=\(session.pid)")
                emitFeed(.system(reason, pid: session.pid, at: timestamp))
            }
        }

        if !output.isEmpty {
            emitFeed(.toolResult(output: output, pid: session.pid, at: timestamp))
        }
    }

    /// Flatten a tool_response into displayable text. Handles the Bash shape
    /// ({stdout, stderr}), plain strings, and MCP content arrays
    /// ({content: [{type: "text", text: ...}]} or a bare array of items).
    static func extractResponseText(_ response: AnyCodable) -> String {
        if let str = response.stringValue { return str }
        if let dict = response.dictValue {
            let stdout = dict["stdout"]?.stringValue ?? ""
            let stderr = dict["stderr"]?.stringValue ?? ""
            if !stdout.isEmpty || !stderr.isEmpty {
                return [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if let content = dict["content"]?.arrayValue {
                return content.compactMap { $0.dictValue?["text"]?.stringValue }
                    .joined(separator: "\n")
            }
            return ""
        }
        if let arr = response.arrayValue {
            return arr.compactMap { $0.dictValue?["text"]?.stringValue }
                .joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Helpers

    private func sendResponse(
        _ decision: Decision,
        payload: PreToolUsePayload? = nil,
        session: Session? = nil,
        respond: ((Data) -> Void)?
    ) {
        // Diagnostic breadcrumb: every hook response that reaches the worker
        // should produce a `[hook] respond ...` line. If a `[socket] enter`
        // ever lacks a matching `[hook] respond` and `[socket] exit wrote=N`
        // (with N > 0), the worker died/wedged after read but before write.
        let reasonTag = decision.reason ?? "-"
        gavelLog("[hook] respond pid=\(session?.pid ?? -1) verdict=\(decision.verdict.rawValue) reason=\(reasonTag.prefix(80))")
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

    /// Raise a non-overridable, fail-closed, phone-mirrored approval that enables per-session remote approval only if allowed.
    private func requestRemoteApprovalToggle(session: Session, timestamp: Date) {
        let location = session.cwd.map { " — \($0)" } ?? ""
        let reason = "Session pid \(session.pid)\(location) requests PHONE (remote) approval. Allow enables it until you go idle or send [[/stop-phone]]; deny or ignore leaves it OFF."
        let payload = PreToolUsePayload(toolName: "__EnableRemoteApproval", toolInput: [:])
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let decision = self.approvalCoordinator.requestApproval(
                payload: payload,
                session: session,
                timestamp: timestamp,
                forceDialog: true,
                forceRemoteMirror: true,
                triggerReason: reason
            )
            if decision.verdict == .allow {
                session.setRemoteApprovalEnabled(true, until: nil)
                self.sessionManager.saveActiveSessions()
                self.emitFeed(.system("Remote (phone) approval ENABLED", pid: session.pid, at: timestamp))
            } else {
                self.emitFeed(.system("Remote (phone) approval request denied", pid: session.pid, at: timestamp))
            }
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
