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
        case allowPatternForSession(pattern: String, context: String?, updatedCommand: String?, updatedInput: [String: AnyCodable]?)
        case alwaysDenyPattern(pattern: String, isRegex: Bool, explanation: String?)
        case alwaysAllowPattern(pattern: String, isRegex: Bool)
        case alwaysPromptPattern(pattern: String, isRegex: Bool)
    }

    /// RuleStore for persistent always-deny/always-allow rules.
    var ruleStore: RuleStore?

    struct PendingApproval {
        let payload: PreToolUsePayload
        let session: Session
        let timestamp: Date
        let forceDialog: Bool
        let respond: (Decision) -> Void
    }

    /// Per-session approval state. Each session gets its own panel and queue.
    final class SessionPanel: ObservableObject {
        let pid: Int
        @Published var currentApproval: PendingApproval?
        @Published var queueCount: Int = 0
        var pendingQueue: [PendingApproval] = []
        var panel: NSPanel?

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
        forceDialog: Bool = false
    ) -> Decision {
        if !forceDialog && session.isAutoApproveEnabled {
            return Decision(verdict: .allow, reason: "Auto-approved")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = Decision(verdict: .block, reason: "Approval timed out — fail closed")

        let pending = PendingApproval(
            payload: payload,
            session: session,
            timestamp: timestamp,
            forceDialog: forceDialog
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

    /// Handle the user's decision from the approval panel.
    func handleAction(_ action: Action, on sessionPanel: SessionPanel) {
        guard let current = sessionPanel.currentApproval else { return }

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

    /// Backward-compatible handleAction for callers that don't specify a session panel.
    func handleAction(_ action: Action) {
        guard let sp = activeSessionPanel else { return }
        handleAction(action, on: sp)
    }

    /// Enable auto-approve for a session and flush its pending approvals.
    /// Forced dialogs (from prompt rules / MCP blocks) are NOT flushed.
    func enableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = true

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
    }

    // MARK: - Per-Session Panel Management

    private func showApproval(_ approval: PendingApproval, on sp: SessionPanel) {
        sp.currentApproval = approval
        activeSessionPanel = sp

        if sp.panel == nil {
            createPanel(for: sp)
        }

        // Update title with project context
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
        sp.currentApproval = nil
        if sp.pendingQueue.isEmpty {
            closePanel(on: sp)
        } else {
            let next = sp.pendingQueue.removeFirst()
            sp.queueCount = sp.pendingQueue.count
            showApproval(next, on: sp)
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

        let p = NSPanel(
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

        // Offset each session's panel so they don't stack on top of each other
        let offset = CGFloat(sessionPanels.count - 1) * 30
        if let frame = p.screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(
                x: frame.midX - GavelConstants.panelWidth / 2 + offset,
                y: frame.midY - GavelConstants.panelHeight / 2 - offset
            ))
        }

        sp.panel = p
    }

    /// Replace typographic dashes (macOS smart dashes) with ASCII hyphens.
    static func sanitizeDashes(_ input: String) -> String {
        input.replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
             .replacingOccurrences(of: "\u{2014}", with: "--") // em-dash
             .replacingOccurrences(of: "\u{2012}", with: "-")  // figure dash
    }

    private func closePanel(on sp: SessionPanel) {
        sp.panel?.orderOut(nil)
    }
}

// MARK: - Array helper

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
