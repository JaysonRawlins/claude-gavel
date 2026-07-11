import AppKit
import SwiftUI

/// Coordinates interactive approval dialogs for PreToolUse events.
///
/// Each session (PID) gets its own floating panel so approvals from
/// different projects don't block each other. The socket handler blocks
/// (via semaphore) until the user responds on that session's panel.
final class ApprovalCoordinator: ObservableObject {

    enum Action {
        case allow(context: String?, updatedCommand: String?, updatedInput: [String: AnyCodable]?)
        case deny(context: String?)
        case allowPatternForSession(
            pattern: String, context: String?, updatedCommand: String?,
            updatedInput: [String: AnyCodable]?)
        case suppressRuleForSession(
            ruleId: UUID, context: String?, updatedCommand: String?,
            updatedInput: [String: AnyCodable]?)
        case denyPatternForSession(pattern: String, explanation: String?)
        case alwaysDenyPattern(pattern: String, isRegex: Bool, explanation: String?)
        case alwaysAllowPattern(pattern: String, isRegex: Bool, argConditions: [String: String]?)
        case alwaysPromptPattern(pattern: String, isRegex: Bool)
        case allowSiteForSession(domain: String, context: String?)

        /// Actions that grant a durable (non-Allow-once) allow — refused on nonSuppressible approvals.
        var createsDurableAllow: Bool {
            switch self {
            case .allowPatternForSession, .suppressRuleForSession, .alwaysAllowPattern,
                .allowSiteForSession:
                return true
            default:
                return false
            }
        }
    }

    /// RuleStore for persistent always-deny/always-allow rules.
    var ruleStore: RuleStore?

    /// SessionManager reference for recording user-interaction signals (inactivity timer).
    weak var sessionManager: SessionManager?

    /// Optional Telegram bridge. When set and a session is remote-enabled, approvals
    /// also race against inline phone buttons.
    var remoteBridge: RemoteApprovalBridge?

    struct PendingApproval {
        let id = UUID()
        let payload: PreToolUsePayload
        let session: Session
        let timestamp: Date
        let forceDialog: Bool
        /// Mirror to Telegram even when the session itself isn't phone-enabled — used by the remote-approval enable request so the bootstrap prompt can reach the phone.
        let forceRemoteMirror: Bool
        /// Reason from the engine when dialog was forced. Nil for default-tier prompts.
        let triggerReason: String?
        /// ID of the rule that fired, if any. Drives the "Allow rule for session" affordance.
        let triggeringRuleId: UUID?
        let triggeringRulePattern: String?
        let triggeringRuleIsRegex: Bool
        /// Allow-once only: the coordinator refuses session/persistent-allow actions for this approval.
        let nonSuppressible: Bool
        let resolvable: ResolvableApproval
        let respond: (Decision) -> Void
    }

    /// Per-session approval state. Each session gets its own panel and queue.
    final class SessionPanel: ObservableObject {
        let pid: Int
        @Published var currentApproval: PendingApproval?
        @Published var queueCount: Int = 0
        var pendingQueue: [PendingApproval] = []
        var panel: NSPanel?
        var savedFrame: NSRect?
        var savedCollapsedOrigin: NSPoint?

        init(pid: Int) { self.pid = pid }
    }

    /// Active session panels, keyed by PID.
    private var sessionPanels: [Int: SessionPanel] = [:]

    /// Currently focused session panel (for compatibility with single-panel callers).
    @Published var activeSessionPanel: SessionPanel?

    /// Get or create a SessionPanel for a PID.
    private func sessionPanel(for pid: Int) -> SessionPanel {
        if let existing = sessionPanels[pid] { return existing }
        let sp = SessionPanel(pid: pid)
        sessionPanels[pid] = sp
        return sp
    }

    /// Request approval for a tool use. Blocks the calling thread until the user decides.
    /// Called from socket handler (background thread).
    func requestApproval(
        payload: PreToolUsePayload,
        session: Session,
        timestamp: Date,
        forceDialog: Bool = false,
        forceRemoteMirror: Bool = false,
        triggerReason: String? = nil,
        triggeringRuleId: UUID? = nil,
        nonSuppressible: Bool = false
    ) -> Decision {
        if !forceDialog && session.isAutoApproveEnabled {
            return Decision(verdict: .allow, reason: "Auto-approved")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = Decision(verdict: .block, reason: "Approval timed out — fail closed")

        let resolvable = ResolvableApproval { decision in
            result = decision
            semaphore.signal()
        }

        let firingRule = triggeringRuleId.flatMap { ruleStore?.rule(for: $0) }
        let pending = PendingApproval(
            payload: payload,
            session: session,
            timestamp: timestamp,
            forceDialog: forceDialog,
            forceRemoteMirror: forceRemoteMirror,
            triggerReason: triggerReason,
            triggeringRuleId: triggeringRuleId,
            triggeringRulePattern: firingRule?.pattern,
            triggeringRuleIsRegex: firingRule?.isRegex ?? false,
            nonSuppressible: nonSuppressible,
            resolvable: resolvable
        ) { decision in
            resolvable.resolve(decision, from: .mac)
        }

        DispatchQueue.main.async {
            let sp = self.sessionPanel(for: session.pid)
            if sp.currentApproval == nil {
                self.showApproval(pending, on: sp)
            } else {
                sp.pendingQueue.append(pending)
                sp.queueCount = sp.pendingQueue.count
            }
        }

        maybeSendRemote(pending: pending, resolvable: resolvable)

        let waitResult = semaphore.wait(timeout: .now() + GavelConstants.approvalTimeoutSeconds)
        if waitResult == .timedOut {
            resolvable.resolve(result, from: .timeout)
            DispatchQueue.main.async {
                let sp = self.sessionPanel(for: session.pid)
                self.dismissCurrent(on: sp)
            }
        }
        return result
    }

    /// Whether a pending approval should be mirrored to Telegram: either the session is phone-enabled, or this is a bootstrap request that forces the mirror.
    static func shouldMirrorRemote(forceRemoteMirror: Bool, sessionActive: Bool) -> Bool {
        forceRemoteMirror || sessionActive
    }

    /// Mirror a pending approval to Telegram; credential-gated payloads send metadata + buttons but withhold the command.
    private func maybeSendRemote(pending: PendingApproval, resolvable: ResolvableApproval) {
        guard Self.shouldMirrorRemote(forceRemoteMirror: pending.forceRemoteMirror, sessionActive: pending.session.isRemoteApprovalActive),
              let bridge = remoteBridge else { return }
        let session = pending.session
        let payload = pending.payload
        let pendingId = pending.id
        let withheld = CredentialGate.inspect(payload)
        if let withheld {
            gavelLog("[remote-gate] withheld command — pid=\(session.pid) trigger=\(withheld.logDescription)")
        }
        // Allow-once-only approvals omit the closure so the phone's "Allow for session" button
        // is never offered (and a stale press is a no-op — RemoteApprovalBridge guards on nil).
        let allowSession: (() -> Void)? = pending.nonSuppressible ? nil : {
            let pattern = payload.command ?? payload.filePath ?? "*"
            let rule = SessionRule(toolName: payload.toolName, pattern: pattern)
            DispatchQueue.main.async { session.sessionRules.append(rule) }
        }
        // Browsing-lease button: only for chrome navigate approvals with a
        // parseable URL — the phone twin of the panel's "Allow Site".
        let leaseDomain: String? = (pending.nonSuppressible || payload.toolName != BrowsingLease.navigateTool)
            ? nil
            : BrowsingLease.normalizedHost(fromURL: payload.toolInput["url"]?.stringValue ?? "")
        let allowSite: (() -> Void)? = leaseDomain.map { domain in
            {
                session.grantBrowsingLease(domain: domain)
                gavelLog("[lease] granted pid=\(session.pid) domain=\(domain) via=phone")
            }
        }
        resolvable.addCleanup { [weak self] source, _ in
            // Any remote resolution must clear the Mac panel, or it lingers
            // showing a stale approval. Mac-source skips: the panel already
            // advances itself.
            guard source == .telegram || source == .web else { return }
            DispatchQueue.main.async { self?.dismissPending(id: pendingId, pid: session.pid) }
        }
        let isCommit = payload.toolName == "Bash" && (payload.command?.contains("commit") ?? false)
        // Review link even on credential-withheld commits: the page never
        // shows the command, secret hunks are withheld on-page, and a
        // withheld commit is exactly when phone-side verification matters.
        let reviewURL = isCommit ? makeReviewLink(payload: payload, session: session, resolvable: resolvable) : nil
        // Full-command link on EVERY mirrored approval — Telegram keeps the
        // redacted/truncated summary, full fidelity lives on the tailnet page.
        let commandURL = makeCommandLink(payload: payload, session: session, resolvable: resolvable, triggerReason: pending.triggerReason, withheldInline: withheld != nil, nonSuppressible: pending.nonSuppressible)
        let text = withheld != nil
            ? RemoteApprovalBridge.withheldBody(payload: payload, session: session, hasCommandLink: commandURL != nil)
            : RemoteApprovalBridge.summaryBody(payload: payload, session: session, triggerReason: pending.triggerReason, hasCommandLink: commandURL != nil)
        bridge.notify(resolvable: resolvable, text: text, pid: session.pid, toolName: payload.toolName, withheld: withheld != nil, allowSession: allowSession, offerCommentClean: isCommit && withheld == nil, leaseDomain: leaseDomain, allowSite: allowSite, reviewURL: reviewURL, commandURL: commandURL)
    }

    /// Register the full, unredacted command with the review server and
    /// return its tailnet URL. Failures are soft — nil just means the
    /// Telegram card goes out with the redacted inline text only.
    private func makeCommandLink(payload: PreToolUsePayload, session: Session, resolvable: ResolvableApproval, triggerReason: String?, withheldInline: Bool, nonSuppressible: Bool) -> String? {
        do {
            try DiffReviewServer.shared.start()
        } catch {
            gavelLog("[review] server start failed: \(error.localizedDescription)")
            return nil
        }
        guard let base = TailscaleServe.cachedReviewBaseURL() else { return nil }

        let primary = payload.command ?? payload.filePath
        // Everything except the primary text becomes an args row, so MCP
        // calls (no command/filePath) still show their full input. Scalar
        // args of MCP calls can anchor a scoped Always Allow on the page.
        let isMCP = payload.toolName.hasPrefix("mcp__")
        let primaryKeys: Set<String> = payload.command != nil ? ["command"] : (payload.filePath != nil ? ["file_path", "path"] : [])
        let args = payload.toolInput
            .filter { argName, _ in !primaryKeys.contains(argName) }
            .map { argName, argValue in
                CommandArg(
                    name: argName,
                    value: Self.displayString(argValue),
                    scopable: isMCP && PersistentRule.scalarString(argValue) != nil)
            }
            .sorted { lhs, rhs in lhs.name < rhs.name }

        // Scoped-allow authoring mirrors the Mac panel's gating: MCP calls
        // with at least one scalar arg, never on Allow-once-only paths.
        let offersScopedAllow = !nonSuppressible && args.contains(where: \.scopable)
        let createScopedAllow: (([String: String]) -> String)? = !offersScopedAllow ? nil : { [weak self] conditions in
            let rule = PersistentRule(
                toolName: payload.toolName, pattern: "*", isRegex: false,
                verdict: .allow, argConditions: conditions)
            // Rule mutations happen on main (house pattern for RuleStore) —
            // the page's decision allows THIS call regardless, so the rule
            // landing a tick later loses nothing.
            DispatchQueue.main.async {
                self?.ruleStore?.addRule(rule, origin: "command-page:always-allow-scoped")
            }
            return rule.name
        }

        let label = session.label.isEmpty ? "PID \(session.pid)" : session.label
        let content = CommandContent(
            sessionLabel: label,
            toolName: payload.toolName,
            cwd: payload.cwd ?? session.cwd,
            command: primary,
            args: args,
            triggerReason: triggerReason,
            withheldInline: withheldInline,
            offersScopedAllow: offersScopedAllow)
        let nonce = DiffReviewServer.shared.register(command: content, resolvable: resolvable, createScopedAllow: createScopedAllow)
        gavelLog("[review] command link created pid=\(session.pid) tool=\(payload.toolName) scopedAllow=\(offersScopedAllow) nonce=\(nonce.prefix(8))…")
        return "\(base)/review/\(nonce)"
    }

    /// Full-fidelity display of a tool arg: strings verbatim, everything
    /// else (numbers, bools, nested dicts/arrays) as compact JSON.
    static func displayString(_ value: AnyCodable) -> String {
        if let s = value.stringValue { return s }
        if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(value.value)"
    }

    /// Snapshot the pending commit's diff, register it with the review
    /// server, and return the tailnet review URL. Every failure is soft —
    /// a nil just means the Telegram message goes out without a link.
    private func makeReviewLink(payload: PreToolUsePayload, session: Session, resolvable: ResolvableApproval) -> String? {
        guard let fallbackCwd = payload.cwd ?? session.cwd, let command = payload.command else {
            gavelLog("[review] no cwd/command on commit approval — no review link")
            return nil
        }
        let cwd = DiffCapture.repoDir(command: command, fallback: fallbackCwd)
        guard let captured = DiffCapture.capture(cwd: cwd, command: command) else {
            gavelLog("[review] diff capture failed cwd=\(cwd) — no review link")
            return nil
        }
        guard !captured.diffText.isEmpty else {
            // Empty diff (e.g. --amend reword) — a review page would show nothing.
            gavelLog("[review] empty diff cwd=\(cwd) — no review link")
            return nil
        }
        do {
            try DiffReviewServer.shared.start()
        } catch {
            gavelLog("[review] server start failed: \(error.localizedDescription)")
            return nil
        }
        guard let base = TailscaleServe.cachedReviewBaseURL() else { return nil }
        let content = ReviewContent(
            repoName: URL(fileURLWithPath: cwd).lastPathComponent,
            commitMessage: captured.commitMessage,
            files: DiffParser.parse(captured.diffText),
            includesUnstaged: captured.includesUnstaged,
            truncated: captured.truncated,
            untrackedOmitted: captured.untrackedOmitted)
        let nonce = DiffReviewServer.shared.register(content: content, resolvable: resolvable)
        gavelLog("[review] link created pid=\(session.pid) files=\(content.files.count) nonce=\(nonce.prefix(8))…")
        return "\(base)/review/\(nonce)"
    }

    /// Remove a pending approval resolved remotely from its session panel.
    private func dismissPending(id: UUID, pid: Int) {
        guard let sp = sessionPanels[pid] else { return }
        if sp.currentApproval?.id == id {
            advanceQueue(on: sp)
        } else if let index = sp.pendingQueue.firstIndex(where: { $0.id == id }) {
            sp.pendingQueue.remove(at: index)
            sp.queueCount = sp.pendingQueue.count
        }
    }

    /// Handle the user's decision from the approval panel.
    func handleAction(_ action: Action, on sessionPanel: SessionPanel) {
        let presentMarker = sessionPanel.currentApproval == nil ? "MISSING" : "ok"
        gavelLog(
            "[approval] action pid=\(sessionPanel.pid) currentApproval=\(presentMarker) action=\(actionLogTag(action))"
        )
        guard let current = sessionPanel.currentApproval else { return }

        // Guardrail-mutation paths are Allow-once only: refuse any durable-allow action and make
        // the user re-decide. The HookRouter already won't consult session rules for these, so a
        // rule created here would be dead anyway — failing loudly is clearer than silently no-op.
        if current.nonSuppressible, action.createsDurableAllow {
            gavelLog("[approval] refused durable-allow on nonSuppressible path pid=\(sessionPanel.pid) action=\(actionLogTag(action))")
            current.respond(Decision(
                verdict: .block,
                reason: "Allow-once only for this path (Gavel/Claude config) — session and persistent allow are refused"))
            advanceQueue(on: sessionPanel)
            return
        }

        // Build updatedInput if user modified the command
        func buildUpdatedInput(_ updatedCommand: String?) -> [String: AnyCodable]? {
            guard let cmd = updatedCommand, cmd != current.payload.command else { return nil }
            var input = current.payload.toolInput
            input["command"] = AnyCodable(cmd)
            return input
        }

        let ctx: String?
        let updated: [String: AnyCodable]?

        switch action {
        case .allow(let context, let updatedCommand, let fieldUpdates):
            ctx = context
            updated = fieldUpdates ?? buildUpdatedInput(updatedCommand)
            current.respond(
                Decision(
                    verdict: .allow, reason: "User approved", additionalContext: ctx,
                    updatedInput: updated))
        case .deny(let context):
            let reason: String
            if let note = context, !note.isEmpty {
                reason = "User denied — \(note)"
            } else {
                reason = "User denied"
            }
            current.respond(Decision(verdict: .block, reason: reason))
            ctx = nil
            updated = nil
        case .allowPatternForSession(let pattern, let context, let updatedCommand, let fieldUpdates):
            ctx = context
            updated = fieldUpdates ?? buildUpdatedInput(updatedCommand)
            let rule = SessionRule(toolName: current.payload.toolName, pattern: pattern)
            current.session.sessionRules.append(rule)
            current.respond(
                Decision(
                    verdict: .allow,
                    reason: "User approved (\(current.payload.toolName): \(pattern))",
                    additionalContext: ctx, updatedInput: updated))

        case .allowSiteForSession(let domain, let context):
            ctx = context
            updated = nil
            current.session.grantBrowsingLease(domain: domain)
            gavelLog("[lease] granted pid=\(current.session.pid) domain=\(domain)")
            current.respond(
                Decision(
                    verdict: .allow,
                    reason: "Browsing lease granted: \(domain) (session, auto-revokes on site drift)",
                    additionalContext: ctx))

        case .suppressRuleForSession(let ruleId, let context, let updatedCommand, let fieldUpdates):
            ctx = context
            updated = fieldUpdates ?? buildUpdatedInput(updatedCommand)
            current.session.suppressedRuleIds.insert(ruleId)
            let patternTag = current.triggeringRulePattern.map { " (\($0))" } ?? ""
            current.respond(
                Decision(
                    verdict: .allow,
                    reason: "User approved — rule suppressed for session\(patternTag)",
                    additionalContext: ctx, updatedInput: updated))

        case .denyPatternForSession(let pattern, let explanation):
            ctx = nil
            updated = nil
            let explText = (explanation?.isEmpty == false) ? explanation : nil
            let rule = SessionRule(
                toolName: current.payload.toolName, pattern: pattern, verdict: .block,
                explanation: explText)
            current.session.sessionRules.append(rule)
            var reason = "Session deny: \(current.payload.toolName): \(pattern)"
            if let e = explText { reason += " — \(e)" }
            current.respond(Decision(verdict: .block, reason: reason, additionalContext: explText))

        case .alwaysDenyPattern(let pattern, let isRegex, let explanation):
            ctx = nil
            updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let explText = (explanation?.isEmpty == false) ? explanation : nil
            let rule = PersistentRule(
                toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex,
                verdict: .block, explanation: explText)
            ruleStore?.addRule(rule, origin: "approval-panel:always-deny")
            var reason = "Always deny: \(current.payload.toolName): \(pattern)"
            if let e = explText { reason += " — \(e)" }
            current.respond(Decision(verdict: .block, reason: reason))

        case .alwaysAllowPattern(let pattern, let isRegex, let argConditions):
            ctx = nil
            updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(
                toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex,
                verdict: .allow, argConditions: argConditions)
            ruleStore?.addRule(rule, origin: "approval-panel:always-allow")
            current.respond(
                Decision(
                    // rule.name carries the arg-condition suffix, so a scoped
                    // allow reads back to the agent as scoped, not blanket.
                    verdict: .allow, reason: "Always allow: \(rule.name)"
                ))

        case .alwaysPromptPattern(let pattern, let isRegex):
            ctx = nil
            updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(
                toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex,
                verdict: .prompt)
            ruleStore?.addRule(rule, origin: "approval-panel:always-prompt")
            current.respond(
                Decision(
                    verdict: .allow,
                    reason: "Always prompt rule saved: \(current.payload.toolName): \(pattern)"))
        }

        advanceQueue(on: sessionPanel)
    }

    /// Backward-compatible handleAction for callers that don't specify a session panel.
    func handleAction(_ action: Action) {
        guard let sp = activeSessionPanel else { return }
        handleAction(action, on: sp)
    }

    /// Enable auto-approve for a session and flush its pending approvals.
    /// Forced dialogs (from prompt rules / MCP blocks) are NOT flushed.
    func enableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = true
        sessionManager?.saveActiveSessions()

        guard let sp = sessionPanels[session.pid] else { return }

        // Flush current if not forced
        if let current = sp.currentApproval, !current.forceDialog {
            current.respond(Decision(verdict: .allow, reason: "Auto-approved"))
            sp.currentApproval = nil
        }
        // Flush queued items — but not forced ones
        let (flushable, remaining) = sp.pendingQueue.partitioned { !$0.forceDialog }
        for pending in flushable {
            pending.respond(Decision(verdict: .allow, reason: "Auto-approved"))
        }
        sp.pendingQueue = remaining
        sp.queueCount = sp.pendingQueue.count

        if sp.currentApproval == nil {
            if sp.pendingQueue.isEmpty {
                closePanel(on: sp)
            } else {
                showApproval(sp.pendingQueue.removeFirst(), on: sp)
                sp.queueCount = sp.pendingQueue.count
            }
        }
    }

    func disableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = false
        sessionManager?.saveActiveSessions()
    }

    // MARK: - Per-Session Panel Management

    private func showApproval(_ approval: PendingApproval, on sp: SessionPanel) {
        gavelLog(
            "[approval] show pid=\(sp.pid) tool=\(approval.payload.toolName) queueDepth=\(sp.pendingQueue.count) trigger=\(approval.triggerReason ?? "-")"
        )
        sp.currentApproval = approval
        activeSessionPanel = sp

        if sp.panel == nil {
            createPanel(for: sp)
        }

        // Update title with project context
        let cwdSuffix =
            approval.session.cwd.map { cwd in
                let parts = cwd.split(separator: "/").suffix(2).joined(separator: "/")
                return " — \(parts)"
            } ?? ""
        sp.panel?.title = "Gavel — PID \(sp.pid)\(cwdSuffix)"

        sp.panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSSound(named: "Tink")?.play()
    }

    private func advanceQueue(on sp: SessionPanel) {
        gavelLog("[approval] advance pid=\(sp.pid) remaining=\(sp.pendingQueue.count)")
        sp.currentApproval = nil
        if sp.pendingQueue.isEmpty {
            closePanel(on: sp)
        } else {
            let next = sp.pendingQueue.removeFirst()
            sp.queueCount = sp.pendingQueue.count
            showApproval(next, on: sp)
        }
    }

    /// Compact tag for the action enum, used in diagnostic logs. Avoids
    /// dumping the full enum (which would include user-typed notes) into
    /// gavel.log.
    private func actionLogTag(_ action: Action) -> String {
        switch action {
        case .allow: return "allow"
        case .deny: return "deny"
        case .allowPatternForSession: return "allowPatternForSession"
        case .suppressRuleForSession: return "suppressRuleForSession"
        case .denyPatternForSession: return "denyPatternForSession"
        case .alwaysDenyPattern: return "alwaysDenyPattern"
        case .alwaysAllowPattern: return "alwaysAllowPattern"
        case .alwaysPromptPattern: return "alwaysPromptPattern"
        case .allowSiteForSession: return "allowSiteForSession"
        }
    }

    private func dismissCurrent(on sp: SessionPanel) {
        sp.currentApproval = nil
        if sp.pendingQueue.isEmpty {
            closePanel(on: sp)
        } else {
            advanceQueue(on: sp)
        }
    }

    private func createPanel(for sp: SessionPanel) {
        let contentView = ApprovalPanelView(coordinator: self, sessionPanel: sp)
        let hostingView = NSHostingView(rootView: contentView)

        // Use a panel subclass that ignores plain Escape. Default NSPanel
        // behavior: Escape (and Cmd+.) call `cancelOperation` which closes
        // the panel. That orphans the pending approval (worker still
        // blocked on its semaphore) and leaves the user with no UI to
        // resolve it. The Deny button's `Cmd+Escape` shortcut still fires
        // because it's handled at the SwiftUI level before reaching the
        // window's cancelOperation.
        let p = NoEscapeNSPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: GavelConstants.panelWidth, height: GavelConstants.panelHeight),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Gavel — PID \(sp.pid)"
        p.contentView = hostingView
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true

        // Offset each session's panel so they don't stack on top of each other
        let offset = CGFloat(sessionPanels.count - 1) * 30
        let frame = Self.activeScreen().visibleFrame
        p.setFrameOrigin(
            NSPoint(
                x: frame.midX - GavelConstants.panelWidth / 2 + offset,
                y: frame.midY - GavelConstants.panelHeight / 2 - offset
            ))

        sp.panel = p
    }

    /// The screen under the mouse cursor, so a panel opens where the user is working rather than on the main display.
    static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Replace typographic dashes (macOS smart dashes) with ASCII hyphens.
    static func sanitizeDashes(_ input: String) -> String {
        input.replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
            .replacingOccurrences(of: "\u{2014}", with: "--")  // em-dash
            .replacingOccurrences(of: "\u{2012}", with: "-")  // figure dash
    }

    private func closePanel(on sp: SessionPanel) {
        sp.panel?.orderOut(nil)
    }
}

// MARK: - Array helper

extension Array {
    fileprivate func partitioned(by predicate: (Element) -> Bool) -> (
        matching: [Element], rest: [Element]
    ) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) { matching.append(element) } else { rest.append(element) }
        }
        return (matching, rest)
    }
}

// MARK: - Escape-resistant panel

/// NSPanel that swallows the default `cancelOperation:` (plain Escape).
/// Without this, pressing Escape in the approval dialog closes the panel
/// without resolving the pending approval — the worker thread stays blocked
/// on its semaphore and the user has no UI to dismiss it. The Deny button's
/// Cmd+Escape SwiftUI shortcut still fires because it's intercepted before
/// the keystroke reaches NSWindow's cancelOperation handling.
private final class NoEscapeNSPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        // intentional no-op — leave the dialog open so the user must
        // explicitly choose Cmd+Return (allow) or Cmd+Escape (deny).
    }
}
