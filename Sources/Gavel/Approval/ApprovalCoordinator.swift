import AppKit
import SwiftUI

/// Coordinates interactive approval dialogs for PreToolUse events.
///
/// When auto-approve is off, queues incoming requests and shows a floating
/// panel for each one. The socket handler blocks (via semaphore) until
/// the user responds.
final class ApprovalCoordinator: ObservableObject {

    enum Action {
        case allow(context: String?, updatedCommand: String?)
        case deny(context: String?)
        case allowPatternForSession(pattern: String, context: String?, updatedCommand: String?)
        case alwaysDenyPattern(pattern: String, isRegex: Bool)
        case alwaysAllowPattern(pattern: String, isRegex: Bool)
    }

    /// RuleStore for persistent always-deny/always-allow rules.
    var ruleStore: RuleStore?

    struct PendingApproval {
        let payload: PreToolUsePayload
        let session: Session
        let timestamp: Date
        let respond: (Decision) -> Void
    }

    @Published var currentApproval: PendingApproval?
    @Published var queueCount: Int = 0

    private var pendingQueue: [PendingApproval] = []
    private var panel: NSPanel?

    /// Request approval for a tool use. Blocks the calling thread until the user decides.
    /// Called from socket handler (background thread).
    /// Set `forceDialog` to true to show the dialog even under auto-approve (used for MCP writes).
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
            timestamp: timestamp
        ) { decision in
            result = decision
            semaphore.signal()
        }

        DispatchQueue.main.async {
            if self.currentApproval == nil {
                self.showApproval(pending)
            } else {
                self.pendingQueue.append(pending)
                self.queueCount = self.pendingQueue.count
            }
        }

        // Block socket handler until user responds (24 hours — effectively no timeout)
        let waitResult = semaphore.wait(timeout: .now() + 86400)
        if waitResult == .timedOut {
            DispatchQueue.main.async {
                self.dismissCurrent()
            }
        }
        return result
    }

    /// Handle the user's decision from the approval panel.
    func handleAction(_ action: Action) {
        guard let current = currentApproval else { return }

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
        case .allow(let context, let updatedCommand):
            ctx = context
            updated = buildUpdatedInput(updatedCommand)
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
        case .allowPatternForSession(let pattern, let context, let updatedCommand):
            ctx = context
            updated = buildUpdatedInput(updatedCommand)
            let rule = SessionRule(toolName: current.payload.toolName, pattern: pattern)
            current.session.sessionRules.append(rule)
            current.respond(Decision(verdict: .allow, reason: "User approved (\(current.payload.toolName): \(pattern))", additionalContext: ctx, updatedInput: updated))

        case .alwaysDenyPattern(let pattern, let isRegex):
            ctx = nil; updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex, verdict: .block)
            ruleStore?.addRule(rule)
            current.respond(Decision(verdict: .block, reason: "Always deny: \(current.payload.toolName): \(pattern)"))

        case .alwaysAllowPattern(let pattern, let isRegex):
            ctx = nil; updated = nil
            let sanitized = Self.sanitizeDashes(pattern)
            let rule = PersistentRule(toolName: current.payload.toolName, pattern: sanitized, isRegex: isRegex, verdict: .allow)
            ruleStore?.addRule(rule)
            current.respond(Decision(verdict: .allow, reason: "Always allow: \(current.payload.toolName): \(pattern)"))
        }

        advanceQueue()
    }

    /// Enable auto-approve for a session and flush its pending approvals.
    func enableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = true

        // Flush current if it belongs to this session
        if let current = currentApproval, current.session.pid == session.pid {
            current.respond(Decision(verdict: .allow, reason: "Auto-approved"))
            currentApproval = nil
        }
        // Flush queued items for this session
        let (forSession, remaining) = pendingQueue.partitioned { $0.session.pid == session.pid }
        for pending in forSession {
            pending.respond(Decision(verdict: .allow, reason: "Auto-approved"))
        }
        pendingQueue = remaining
        queueCount = pendingQueue.count

        if currentApproval == nil {
            if pendingQueue.isEmpty {
                closePanel()
            } else {
                showApproval(pendingQueue.removeFirst())
                queueCount = pendingQueue.count
            }
        }
    }

    func disableAutoApprove(for session: Session) {
        session.isAutoApproveEnabled = false
    }

    // MARK: - Panel Management

    private func showApproval(_ approval: PendingApproval) {
        currentApproval = approval

        if panel == nil {
            createPanel()
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Play a sound to get attention
        NSSound(named: "Tink")?.play()
    }

    private func advanceQueue() {
        currentApproval = nil
        if pendingQueue.isEmpty {
            closePanel()
        } else {
            let next = pendingQueue.removeFirst()
            queueCount = pendingQueue.count
            showApproval(next)
        }
    }

    private func dismissCurrent() {
        currentApproval = nil
        if pendingQueue.isEmpty {
            closePanel()
        } else {
            advanceQueue()
        }
    }

    private func createPanel() {
        let contentView = ApprovalPanelView(coordinator: self)
        let hostingView = NSHostingView(rootView: contentView)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Gavel — Approve Tool Use"
        p.contentView = hostingView
        p.center()
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // Allow text editing operations (paste, cut, copy, select all)
        p.acceptsMouseMovedEvents = true
        panel = p
    }

    /// Replace typographic dashes (macOS smart dashes) with ASCII hyphens.
    static func sanitizeDashes(_ input: String) -> String {
        input.replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
             .replacingOccurrences(of: "\u{2014}", with: "--") // em-dash
             .replacingOccurrences(of: "\u{2012}", with: "-")  // figure dash
    }

    private func closePanel() {
        panel?.orderOut(nil)
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
