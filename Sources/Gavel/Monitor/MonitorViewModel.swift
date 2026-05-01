import Foundation
import SwiftUI
import Combine

/// ViewModel for the monitor window. Bridges daemon events to the SwiftUI view.
final class MonitorViewModel: ObservableObject {
    @Published var feedEntries: [FeedDisplayEntry] = []
    @Published var isPaused: Bool = false
    @Published var autoApproveText: String = "Interactive approval"
    @Published var sessionRulesText: String = "Session rules: none"
    @Published var statsText: String = "Tools: 0 | Allow: 0 | Block: 0"
    @Published var uptimeText: String = "0m"

    // Regex tester state (persists across tab switches)
    @Published var testerPattern: String = ""
    @Published var testerTestString: String = ""
    @Published var testerIsRegex: Bool = true

    /// User-pinned session PID. Click any row to pin (highlight); click the
    /// pinned row again to unpin. In-memory only — fresh on app restart.
    /// Lingers if the pinned session ends; the UI just renders no highlight
    /// until the user pins something else.
    @Published var pinnedSessionPid: Int?

    let approvalCoordinator: ApprovalCoordinator
    let sessionManager: SessionManager
    private let maxFeedEntries = GavelConstants.maxFeedEntries
    private let startTime = Date()
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?

    init(sessionManager: SessionManager, approvalCoordinator: ApprovalCoordinator) {
        self.sessionManager = sessionManager
        self.approvalCoordinator = approvalCoordinator
        startStatsTimer()
    }

    deinit {
        statsTimer?.invalidate()
    }

    func appendFeedEntry(_ entry: FeedEntry) {
        let display = FeedDisplayEntry(from: entry)
        feedEntries.append(display)
        if feedEntries.count > maxFeedEntries {
            feedEntries.removeFirst(feedEntries.count - maxFeedEntries)
        }
    }

    // MARK: - Controls

    func togglePin(for session: Session) {
        if pinnedSessionPid == session.pid {
            pinnedSessionPid = nil
        } else {
            pinnedSessionPid = session.pid
        }
        noteInteraction()
    }

    func toggleAutoApprove(for session: Session) {
        if session.isAutoApproveEnabled {
            approvalCoordinator.disableAutoApprove(for: session)
        } else {
            approvalCoordinator.enableAutoApprove(for: session)
        }
        // Never persist auto-approve as default — new sessions must opt in explicitly.
        // This prevents a minimized/hidden monitor from silently auto-approving new sessions.
        sessionManager.saveDefaults()
    }

    func togglePause() {
        guard let session = sessionManager.sessions.values.first else { return }
        session.isPaused.toggle()
        isPaused = session.isPaused
    }

    func revokeAutoApprove() {
        for session in sessionManager.sessions.values {
            session.revokeAutoApprove()
        }
    }

    /// Revoke auto across every session + reset defaults + notify. The menu bar
    /// "Prompt All Sessions" action and the inactivity timer both call through here.
    func promptAllSessions() {
        sessionManager.promptAllSessions()
    }

    /// Revoke auto on a single session and record user activity.
    /// One-click alternative to toggling both Auto and Sub off manually.
    func promptSession(_ session: Session) {
        session.revokeAutoApprove()
        sessionManager.noteInteraction()
    }

    /// Record any direct user interaction with gavel's UI. Resets the inactivity timer.
    func noteInteraction() {
        sessionManager.noteInteraction()
    }

    var ruleCount: Int {
        approvalCoordinator.ruleStore?.rules.count ?? 0
    }

    var persistentRules: [PersistentRule] {
        approvalCoordinator.ruleStore?.rules ?? []
    }

    func addRule(_ rule: PersistentRule) {
        approvalCoordinator.ruleStore?.addRule(rule)
    }

    func deleteRule(id: UUID) {
        approvalCoordinator.ruleStore?.removeRule(id: id)
    }

    func updateRule(id: UUID, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String?) {
        approvalCoordinator.ruleStore?.updateRule(id: id, pattern: pattern, isRegex: isRegex, verdict: verdict, explanation: explanation)
    }

    func exportRules(to url: URL) throws {
        guard let rules = approvalCoordinator.ruleStore?.rules else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: url)
    }

    /// Import rules from a JSON file. Returns the number of rules imported.
    @discardableResult
    func importRules(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let rules = try JSONDecoder().decode([PersistentRule].self, from: data)
        guard !rules.isEmpty else { return 0 }
        for rule in rules {
            approvalCoordinator.ruleStore?.addRule(rule)
        }
        return rules.count
    }

    func killSession() {
        guard let session = sessionManager.sessions.values.first, session.isAlive else { return }
        kill(Int32(session.pid), SIGINT)
        revokeAutoApprove()
    }

    // MARK: - Stats

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    private func updateStats() {
        let uptime = Int(Date().timeIntervalSince(startTime))
        let mins = uptime / 60
        let secs = uptime % 60
        uptimeText = "\(mins)m \(String(format: "%02d", secs))s"

        var totalTools = 0
        var totalAllow = 0
        var totalBlock = 0
        var allowRuleCount = 0
        var denyRuleCount = 0
        var autoCount = 0

        for session in sessionManager.sessions.values {
            totalTools += session.toolCallCount
            totalAllow += session.allowCount
            totalBlock += session.blockCount
            allowRuleCount += session.sessionRules.filter { $0.verdict == .allow }.count
            denyRuleCount += session.sessionRules.filter { $0.verdict == .block }.count
            if session.isAutoApproveEnabled { autoCount += 1 }
        }

        let totalRules = allowRuleCount + denyRuleCount
        let sessionCount = sessionManager.sessions.count
        statsText = "Tools: \(totalTools) | Allow: \(totalAllow) | Block: \(totalBlock)"
        if totalRules == 0 {
            sessionRulesText = "Session rules: none"
        } else if denyRuleCount == 0 {
            sessionRulesText = "Session rules: \(totalRules) allow"
        } else if allowRuleCount == 0 {
            sessionRulesText = "Session rules: \(totalRules) deny"
        } else {
            sessionRulesText = "Session rules: \(allowRuleCount) allow, \(denyRuleCount) deny"
        }
        if sessionCount == 0 {
            autoApproveText = "No active sessions"
        } else if autoCount == sessionCount {
            autoApproveText = "Auto-approve: all \(sessionCount) sessions"
        } else if autoCount > 0 {
            autoApproveText = "Auto-approve: \(autoCount)/\(sessionCount) sessions"
        } else {
            autoApproveText = "Interactive approval (\(sessionCount) sessions)"
        }
    }
}
