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
        var ruleCount = 0
        var autoCount = 0

        for session in sessionManager.sessions.values {
            totalTools += session.toolCallCount
            totalAllow += session.allowCount
            totalBlock += session.blockCount
            ruleCount += session.sessionRules.count
            if session.isAutoApproveEnabled { autoCount += 1 }
        }

        let sessionCount = sessionManager.sessions.count
        statsText = "Tools: \(totalTools) | Allow: \(totalAllow) | Block: \(totalBlock)"
        sessionRulesText = ruleCount == 0 ? "Session rules: none" : "Session rules: \(ruleCount) patterns"
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
