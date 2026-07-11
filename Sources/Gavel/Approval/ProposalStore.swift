import Foundation

/// A rule Claude proposed via `gavel-hook propose-rule`, pending user adjudication.
///
/// Proposals are inert — they change zero matching behavior until the user accepts
/// one in the Monitor's Rules tab, at which point it becomes a PersistentRule through
/// the normal RuleStore path (audited, signed, backed up).
struct RuleProposal: Codable, Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let pattern: String
    let isRegex: Bool
    let verdict: DecisionVerdict
    /// Why Claude thinks this footgun needs a gate — shown on the proposal card.
    let reason: String
    /// The concrete command/path that motivated the proposal.
    let example: String?
    let sessionPid: Int
    let sessionId: String?
    let createdAt: Date

    init(toolName: String, pattern: String, isRegex: Bool, verdict: DecisionVerdict,
         reason: String, example: String?, sessionPid: Int, sessionId: String?) {
        self.id = UUID()
        self.toolName = toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.reason = reason
        self.example = example
        self.sessionPid = sessionPid
        self.sessionId = sessionId
        self.createdAt = Date()
    }
}

/// Pending-proposal inbox: validation, dedupe, persistence, and adjudication.
///
/// The mutation direction is enforced HERE, server-side — `submit` only ever
/// accepts deny/prompt verdicts, so no client flag or crafted payload can use
/// the proposal channel to widen permissions. Submit arrives on the socket
/// worker queue; accept/reject are user actions from the Monitor (main thread).
/// State is a lock-guarded plain array (not @Published) so worker-thread
/// mutations never trip SwiftUI's main-thread invariant — UI observers mirror
/// snapshots via `onChange`, which always fires on main.
final class ProposalStore {
    /// Fired on the main thread after any mutation, with a snapshot of pending proposals.
    var onChange: (([RuleProposal]) -> Void)?

    /// Fired (main thread) once per successfully queued proposal — the hook
    /// for mirroring it to the phone. Delivery is best-effort; the inbox
    /// here stays the source of truth either way.
    var onSubmitted: ((RuleProposal) -> Void)?

    /// Set at wiring time; used for dedupe against existing rules and for accept.
    weak var ruleStore: RuleStore?

    static let maxPendingPerSession = 10
    static let ttl: TimeInterval = 7 * 24 * 3600
    private static let maxPatternLength = 500
    private static let maxTextLength = 1000

    private let path: String
    private let lock = NSLock()
    private var storage: [RuleProposal] = []

    enum SubmitResult: Equatable {
        case queued(UUID)
        case rejected(String)
    }

    init(path: String? = nil) {
        self.path = path ?? Self.defaultPath
        load()
    }

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/gavel/proposals.json"
    }

    var proposals: [RuleProposal] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: - Submit (socket worker queue)

    func submit(toolName: String, pattern: String, isRegex: Bool, verdict rawVerdict: String,
                reason: String, example: String?, sessionPid: Int, sessionId: String?) -> SubmitResult {
        let verdict: DecisionVerdict
        switch rawVerdict.lowercased() {
        case "deny", "block": verdict = .block
        case "prompt", "ask": verdict = .prompt
        case "allow":
            return .rejected("Proposals are tighten-only: allow rules can't be proposed — ask the user to add one in the Monitor")
        default:
            return .rejected("Unknown verdict \"\(rawVerdict)\" — use deny or prompt")
        }

        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tool.isEmpty else { return .rejected("Missing tool name") }
        guard !pat.isEmpty else { return .rejected("Missing pattern") }
        guard why.count >= 10 else { return .rejected("Reason required — say why this needs a gate") }
        guard pat.count <= Self.maxPatternLength else { return .rejected("Pattern too long (max \(Self.maxPatternLength) chars)") }
        guard why.count <= Self.maxTextLength else { return .rejected("Reason too long (max \(Self.maxTextLength) chars)") }
        guard PersistentRule.compilePattern(pat, isRegex: isRegex) != nil else {
            return .rejected("Pattern does not compile as \(isRegex ? "regex" : "glob")")
        }

        if let existing = ruleStore?.rules.first(where: { $0.toolName == tool && $0.pattern == pat && !$0.isDisabled }) {
            return .rejected("Duplicate of existing rule (\(existing.verdict.rawValue)): \(existing.name)")
        }

        lock.lock()
        pruneExpiredLocked()
        if storage.contains(where: { $0.toolName == tool && $0.pattern == pat }) {
            lock.unlock()
            return .rejected("Already proposed and pending review")
        }
        if storage.filter({ $0.sessionPid == sessionPid }).count >= Self.maxPendingPerSession {
            lock.unlock()
            return .rejected("Too many pending proposals from this session (max \(Self.maxPendingPerSession)) — wait for the user to review")
        }

        let proposal = RuleProposal(
            toolName: tool, pattern: pat, isRegex: isRegex, verdict: verdict,
            reason: why, example: example?.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionPid: sessionPid, sessionId: sessionId
        )
        storage.append(proposal)
        saveLocked()
        lock.unlock()

        notifyChanged()
        DispatchQueue.main.async { [weak self] in
            self?.onSubmitted?(proposal)
        }
        return .queued(proposal.id)
    }

    // MARK: - Adjudication (Monitor UI / remote bridge)

    /// Accept: promote to a PersistentRule via the audited RuleStore path, drop the proposal.
    @discardableResult
    func accept(id: UUID, via channel: String = "monitor") -> PersistentRule? {
        guard let proposal = removeProposal(id: id) else { return nil }

        let rule = PersistentRule(
            toolName: proposal.toolName, pattern: proposal.pattern, isRegex: proposal.isRegex,
            verdict: proposal.verdict, explanation: proposal.reason
        )
        ruleStore?.addRule(rule, origin: "claude-proposal pid=\(proposal.sessionPid) accepted-via=\(channel)")
        notifyChanged()
        return rule
    }

    func reject(id: UUID, via channel: String = "monitor") {
        guard let proposal = removeProposal(id: id) else { return }

        ruleStore?.auditLog?.record(
            action: "proposal_rejected",
            origin: "claude-proposal pid=\(proposal.sessionPid) rejected-via=\(channel)",
            toolName: proposal.toolName, pattern: proposal.pattern,
            verdict: proposal.verdict.rawValue, detail: proposal.reason
        )
        notifyChanged()
    }

    private func removeProposal(id: UUID) -> RuleProposal? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = storage.firstIndex(where: { $0.id == id }) else { return nil }
        let proposal = storage.remove(at: idx)
        saveLocked()
        return proposal
    }

    // MARK: - Persistence

    private struct ProposalsFile: Codable {
        var version: Int
        var proposals: [RuleProposal]
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(ProposalsFile.self, from: data) else { return }
        storage = file.proposals.filter { Date().timeIntervalSince($0.createdAt) < Self.ttl }
    }

    private func pruneExpiredLocked() {
        let kept = storage.filter { Date().timeIntervalSince($0.createdAt) < Self.ttl }
        if kept.count != storage.count {
            storage = kept
            saveLocked()
        }
    }

    private func saveLocked() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ProposalsFile(version: 1, proposals: storage)) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func notifyChanged() {
        let snapshot = proposals
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(snapshot)
        }
    }
}
