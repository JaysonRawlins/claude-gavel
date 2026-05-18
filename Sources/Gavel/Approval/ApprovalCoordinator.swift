import AppKit
import SwiftUI

/// Per-session approval dialogs — each PID gets its own floating panel and semaphore so approvals from different projects don't block each other.
final class ApprovalCoordinator: ObservableObject {
    enum Action {
        case allow(context: String?, updatedCommand: String?, updatedInput: [String: AnyCodable]?)
        case deny(context: String?)
        case allowPatternForSession(pattern: String, context: String?, updatedCommand: String?, updatedInput: [String: AnyCodable]?)
        /// Suppress firing prompt rule for the session — covers the rule's full regex scope, broader than a single pattern.
        case suppressRuleForSession(ruleId: UUID, context: String?, updatedCommand: String?, updatedInput: [String: AnyCodable]?)
        case denyPatternForSession(pattern: String, explanation: String?)
        case alwaysDenyPattern(pattern: String, isRegex: Bool, explanation: String?)
        case alwaysAllowPattern(pattern: String, isRegex: Bool)
        case alwaysPromptPattern(pattern: String, isRegex: Bool)
    }

    var ruleStore: RuleStore?

    weak var sessionManager: SessionManager?

    struct PendingApproval {
        let payload: PreToolUsePayload
        let session: Session
        let timestamp: Date
        let forceDialog: Bool
        let triggerReason: String?
        let triggeringRuleId: UUID?
        let triggeringRulePattern: String?
        let triggeringRuleIsRegex: Bool
        let respond: (Decision) -> Void
    }

    final class SessionPanel: ObservableObject {
        let pid: Int
        @Published var currentApproval: PendingApproval?
        @Published var queueCount: Int = 0
        var pendingQueue: [PendingApproval] = []
        var panel: NSPanel?

        init(pid: Int) { self.pid = pid }
    }

    private var sessionPanels: [Int: SessionPanel] = [:]

    @Published var activeSessionPanel: SessionPanel?

    private func sessionPanel(for pid: Int) -> SessionPanel {
        if let existing = sessionPanels[pid] { return existing }
        let sp = SessionPanel(pid: pid)
        sessionPanels[pid] = sp
        return sp
    }

    /// Blocks the calling thread until the user decides — called from the socket worker.
    func requestApproval(
        payload: PreToolUsePayload,
        session: Session,
        timestamp: Date,
        forceDialog: Bool = false,
        triggerReason: String? = nil,
        triggeringRuleId: UUID? = nil
    ) -> Decision {
        if !forceDialog && session.isAutoApproveEnabled {
            return Decision(verdict: .allow, reason: "Auto-approved")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = Decision(verdict: .block, reason: "Approval timed out — fail closed")

        let firingRule = triggeringRuleId.flatMap { ruleStore?.rule(for: $0) }
        let pending = PendingApproval(
            payload: payload,
            session: session,
            timestamp: timestamp,
            forceDialog: forceDialog,
            triggerReason: triggerReason,
            triggeringRuleId: triggeringRuleId,
            triggeringRulePattern: firingRule?.pattern,
            triggeringRuleIsRegex: firingRule?.isRegex ?? false
        ) { decision in
            result = decision
            semaphore.signal()
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

        let waitResult = semaphore.wait(timeout: .now() + GavelConstants.approvalTimeoutSeconds)
        if waitResult == .timedOut {
            DispatchQueue.main.async {
                let sp = self.sessionPanel(for: session.pid)
                self.dismissCurrent(on: sp)
            }
        }
        return result
    }

    func handleAction(_ action: Action, on sessionPanel: SessionPanel) {
        // Diagnostic breadcrumb. `currentApproval == MISSING` here means a click dropped silently — semaphore never signals, hook waits forever.
        let presentMarker = sessionPanel.currentApproval == nil ? "MISSING" : "ok"
        gavelLog("[approval] action pid=\(sessionPanel.pid) currentApproval=\(presentMarker) action=\(actionLogTag(action))")
        guard let current = sessionPanel.currentApproval else { return }

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
            current.respond(Decision(verdict: .allow, reason: "User approved", additionalContext: ctx, updatedInput: updated))
        case .deny(let context):
            let reason: String
            if let note = context, !note.isEmpty {
                reason = "User denied — \(note)"
            } else {
                reason = "User denied"
            }
            current.respond(Decision(verdict: .block, reason: reason))
            ctx = nil; updated = nil
        case .allowPatternForSession(let pattern, let context, let updatedCommand, let fieldUpdates):
            ctx = context
            updated = fieldUpdates ?? buildUpdatedInput(updatedCommand)
            let rule = SessionRule(toolName: current.payload.toolName, pattern: pattern)
            current.session.sessionRules.append(rule)
            current.respond(Decision(verdict: .allow, reason: "User approved (\(current.payload.toolName): \(pattern))", additionalContext: ctx, updatedInput: updated))

        case .suppressRuleForSession(let ruleId, let context, let updatedCommand, let fieldUpdates):
            ctx = context
            updated = fieldUpdates ?? buildUpdatedInput(updatedCommand)
            current.session.suppressedRuleIds.insert(ruleId)
            let patternTag = current.triggeringRulePattern.map { " (\($0))" } ?? ""
            current.respond(Decision(verdict: .allow, reason: "User approved — rule suppressed for session\(patternTag)", additionalContext: ctx, updatedInput: updated))

        case .denyPatternForSession(let pattern, let explanation):
            ctx = nil; updated = nil
            let explText = (explanation?.isEmpty == false) ? explanation : nil
            let rule = SessionRule(toolName: current.payload.toolName, pattern: pattern, verdict: .block, explanation: explText)
            current.session.sessionRules.append(rule)
            var reason = "Session deny: \(current.payload.toolName): \(pattern)"
            if let e = explText { reason += " — \(e)" }
            current.respond(Decision(verdict: .block, reason: reason, additionalContext: explText))

        case .alwaysDenyPattern(let pattern, let isRegex, let explanation):
            ctx = nil; updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let explText = (explanation?.isEmpty == false) ? explanation : nil
            let rule = PersistentRule(toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex, verdict: .block, explanation: explText)
            ruleStore?.addRule(rule)
            var reason = "Always deny: \(current.payload.toolName): \(pattern)"
            if let e = explText { reason += " — \(e)" }
            current.respond(Decision(verdict: .block, reason: reason))

        case .alwaysAllowPattern(let pattern, let isRegex):
            ctx = nil; updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex, verdict: .allow)
            ruleStore?.addRule(rule)
            current.respond(Decision(verdict: .allow, reason: "Always allow: \(current.payload.toolName): \(pattern)"))

        case .alwaysPromptPattern(let pattern, let isRegex):
            ctx = nil; updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex, verdict: .prompt)
            ruleStore?.addRule(rule)
            current.respond(Decision(verdict: .allow, reason: "Always prompt rule saved: \(current.payload.toolName): \(pattern)"))
        }

        advanceQueue(on: sessionPanel)
    }

    func handleAction(_ action: Action) {
        guard let sp = activeSessionPanel else { return }
        handleAction(action, on: sp)
    }

    func enableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = true
        sessionManager?.saveActiveSessions()

        guard let sp = sessionPanels[session.pid] else { return }

        if let current = sp.currentApproval, !current.forceDialog {
            current.respond(Decision(verdict: .allow, reason: "Auto-approved"))
            sp.currentApproval = nil
        }

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

    private func showApproval(_ approval: PendingApproval, on sp: SessionPanel) {
        gavelLog("[approval] show pid=\(sp.pid) tool=\(approval.payload.toolName) queueDepth=\(sp.pendingQueue.count) trigger=\(approval.triggerReason ?? "-")")
        sp.currentApproval = approval
        activeSessionPanel = sp

        if sp.panel == nil {
            createPanel(for: sp)
        }

        let cwdSuffix = approval.session.cwd.map { cwd in
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

    /// Compact tag for gavel.log — avoids dumping the full enum (which contains user-typed notes) into the log file.
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

        // NoEscapeNSPanel: plain Escape would call `cancelOperation` and close the panel, orphaning the pending approval. Deny's Cmd+Escape SwiftUI shortcut still fires.
        let p = NoEscapeNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: GavelConstants.panelWidth, height: GavelConstants.panelHeight),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Gavel — PID \(sp.pid)"
        p.contentView = hostingView
        p.center()
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true

        let offset = CGFloat(sessionPanels.count - 1) * 30
        if let frame = p.screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(
                x: frame.midX - GavelConstants.panelWidth / 2 + offset,
                y: frame.midY - GavelConstants.panelHeight / 2 - offset
            ))
        }

        sp.panel = p
    }

    /// Replace typographic dashes with ASCII so saved patterns match input that arrives via clipboard/typing where macOS substituted them.
    static func sanitizeDashes(_ input: String) -> String {
        input.replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
             .replacingOccurrences(of: "\u{2014}", with: "--") // em-dash
             .replacingOccurrences(of: "\u{2012}", with: "-")  // figure dash
    }

    private func closePanel(on sp: SessionPanel) {
        sp.panel?.orderOut(nil)
    }
}

private extension Array {
    func partitioned(by predicate: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) { matching.append(element) }
            else { rest.append(element) }
        }
        return (matching, rest)
    }
}

/// NSPanel that swallows plain-Escape `cancelOperation:` — otherwise it'd close the panel and orphan the worker thread blocked on its semaphore. Deny's Cmd+Escape SwiftUI shortcut fires before reaching this method.
private final class NoEscapeNSPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        // Intentional no-op — user must explicitly choose Cmd+Return (allow) or Cmd+Escape (deny).
    }
}
