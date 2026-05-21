import Foundation

/// Live sessions keyed by PID; tombstones keyed by sessionId (so PID reuse can't clobber them).
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Int: Session] = [:]
    @Published private(set) var deadSessions: [String: Session] = [:]

    private let lock = NSLock()
    private var cleanupTimer: DispatchSourceTimer?
    private var inactivityTimer: DispatchSourceTimer?

    /// Default settings applied to new sessions (survives daemon restarts).
    @Published var defaultAutoApprove: Bool = false
    @Published var defaultSubAgentInherit: Bool = false
    @Published var defaultPaused: Bool = false

    /// Inactivity threshold in minutes. 0 disables the timer.
    /// When the user hasn't interacted with gavel for this long, auto-approval
    /// is revoked across all sessions (walk-away defense).
    @Published var inactivityTimeoutMinutes: Int = 15

    /// User-typed labels keyed by Claude Code session UUID. Survives daemon restarts.
    @Published private var sessionLabels: [String: String] = [:]

    private var lastInteraction: Date = Date()

    private let defaultsPath: String
    private let sessionsPath: String

    init(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        autoStartTimers: Bool = true,
        autoDiscover: Bool = true
    ) {
        let base = homeDir.path + "/.claude/gavel"
        self.defaultsPath = base + "/session-defaults.json"
        self.sessionsPath = base + "/active-sessions.json"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

        loadDefaults()
        loadActiveSessions()
        if autoDiscover { discoverRunningSessions() }
        if autoStartTimers {
            startCleanupTimer()
            startInactivityTimer()
        }
    }

    deinit {
        cleanupTimer?.cancel()
        inactivityTimer?.cancel()
    }

    /// Get or create a session for the given PID and agent kind.
    /// New sessions inherit the default Auto/Sub settings.
    func session(for pid: Int, agent: AgentKind = .claude) -> Session {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[pid] {
            return existing
        }
        let session = Session(pid: pid, agent: agent)
        session.isAutoApproveEnabled = defaultAutoApprove
        session.isSubAgentInheritEnabled = defaultSubAgentInherit
        session.isPaused = defaultPaused
        sessions[pid] = session
        saveActiveSessionsLocked()
        return session
    }

    /// Save current defaults to disk (called when user toggles).
    func saveDefaults() {
        let data: [String: Any] = [
            "autoApprove": defaultAutoApprove,
            "subAgentInherit": defaultSubAgentInherit,
            "paused": defaultPaused,
            "inactivityTimeoutMinutes": inactivityTimeoutMinutes,
            "sessionLabels": sessionLabels
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: defaultsPath, contents: json)
        }
    }

    private func loadDefaults() {
        guard let data = FileManager.default.contents(atPath: defaultsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        defaultAutoApprove = (json["autoApprove"] as? Bool) ?? false
        defaultSubAgentInherit = (json["subAgentInherit"] as? Bool) ?? false
        defaultPaused = (json["paused"] as? Bool) ?? false
        inactivityTimeoutMinutes = (json["inactivityTimeoutMinutes"] as? Int) ?? 15
        sessionLabels = (json["sessionLabels"] as? [String: String]) ?? [:]
    }

    /// Worker-thread caller; @Published mutations dispatched to main.
    /// A matching tombstone is dropped — same conversation, new PID.
    func recordSessionId(_ sid: String, on session: Session) {
        let changed = session.sessionId != sid
        let savedLabel = sessionLabels[sid]
        let currentLabel = session.label
        DispatchQueue.main.async {
            session.sessionId = sid
            if session.label.isEmpty, let saved = savedLabel {
                session.label = saved
            }
        }
        if !currentLabel.isEmpty && savedLabel != currentLabel {
            sessionLabels[sid] = currentLabel
            saveDefaults()
        }
        if changed {
            lock.lock()
            deadSessions.removeValue(forKey: sid)
            saveActiveSessionsLocked()
            lock.unlock()
        }
    }

    /// Update the cwd for a session and persist the change.
    /// Worker-thread caller; @Published mutation dispatched to main.
    func recordCwd(_ cwd: String, on session: Session) {
        let changed = session.cwd != cwd
        DispatchQueue.main.async {
            session.cwd = cwd
        }
        if changed {
            lock.lock()
            saveActiveSessionsLocked()
            lock.unlock()
        }
    }

    /// Save (or clear) the label for a session UUID. Empty/whitespace removes the entry.
    func setLabel(_ label: String, for sessionId: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sessionLabels.removeValue(forKey: sessionId)
        } else {
            sessionLabels[sessionId] = trimmed
        }
        saveDefaults()
    }

    func forgetTombstone(sessionId: String) {
        lock.lock()
        if deadSessions.removeValue(forKey: sessionId) != nil {
            saveActiveSessionsLocked()
        }
        lock.unlock()
    }

    func clearDeadSessions() {
        lock.lock()
        let strayPids = sessions.compactMap { (pid, session) -> Int? in
            (!session.isAlive || !isProcessAlive(pid: pid)) ? pid : nil
        }
        for pid in strayPids {
            sessions.removeValue(forKey: pid)
        }
        let hadTombstones = !deadSessions.isEmpty
        deadSessions.removeAll()
        if !strayPids.isEmpty || hadTombstones {
            saveActiveSessionsLocked()
        }
        lock.unlock()
    }

    // MARK: - Active session persistence

    /// Fields beyond `pid` are optional so older on-disk files load cleanly.
    private struct PersistedSession: Codable {
        let pid: Int
        let sessionId: String?
        let cwd: String?
        let isAutoApproveEnabled: Bool?
        let isSubAgentInheritEnabled: Bool?
        let isPaused: Bool?
        let label: String?
        let endedAt: Date?
        let agent: AgentKind?
        let lastPlanPath: String?
        let yoloEngagedAt: Date?
        let yoloPlanPath: String?
        let yoloPlanHash: String?
        let yoloDisabledReason: String?
    }

    private struct PersistedState: Codable {
        let live: [PersistedSession]
        let dead: [PersistedSession]
    }

    /// Persist all live sessions and their per-session toggle state.
    /// Call after any change a user expects to survive a daemon restart
    /// (auto/sub/pause toggle, inactivity-driven auto-revoke, etc.).
    /// Internal locking handled here so callers don't have to remember.
    func saveActiveSessions() {
        lock.lock()
        defer { lock.unlock() }
        saveActiveSessionsLocked()
    }

    /// Caller's responsibility: hold `lock` (or know that no concurrent writer can race).
    private func saveActiveSessionsLocked() {
        let live = sessions.values
            .filter { $0.isAlive }
            .map { snapshotOf($0) }
        let dead = deadSessions.values.map { snapshotOf($0) }
        let state = PersistedState(live: Array(live), dead: Array(dead))
        guard let json = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: sessionsPath, contents: json)
    }

    private func snapshotOf(_ session: Session) -> PersistedSession {
        PersistedSession(
            pid: session.pid,
            sessionId: session.sessionId,
            cwd: session.cwd,
            isAutoApproveEnabled: session.isAutoApproveEnabled,
            isSubAgentInheritEnabled: session.isSubAgentInheritEnabled,
            isPaused: session.isPaused,
            label: session.label.isEmpty ? nil : session.label,
            endedAt: session.endedAt,
            agent: session.agent,
            lastPlanPath: session.lastPlanPath,
            yoloEngagedAt: session.yoloEngagedAt,
            yoloPlanPath: session.yoloPlanPath,
            yoloPlanHash: session.yoloPlanHash,
            yoloDisabledReason: session.yoloDisabledReason
        )
    }

    /// Must run after loadDefaults() so labels are populated before they're applied here.
    private func loadActiveSessions() {
        guard let data = FileManager.default.contents(atPath: sessionsPath) else { return }
        let decoder = JSONDecoder()

        let live: [PersistedSession]
        let dead: [PersistedSession]
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            live = state.live
            dead = state.dead
        } else if let legacy = try? decoder.decode([PersistedSession].self, from: data) {
            live = legacy
            dead = []
        } else {
            return
        }

        for snap in live + dead {
            if isProcessAlive(pid: snap.pid) {
                rehydrateLive(snap)
            } else if let sid = snap.sessionId {
                rehydrateTombstone(snap, sessionId: sid)
            }
        }
    }

    private func rehydrateLive(_ snap: PersistedSession) {
        let started = ProcessTree.startTime(of: Int32(snap.pid))
        let session = Session(pid: snap.pid, cwd: snap.cwd, startedAt: started, agent: snap.agent ?? .claude)
        session.sessionId = snap.sessionId
        session.isAutoApproveEnabled = snap.isAutoApproveEnabled ?? defaultAutoApprove
        session.isSubAgentInheritEnabled = snap.isSubAgentInheritEnabled ?? defaultSubAgentInherit
        session.isPaused = snap.isPaused ?? defaultPaused
        if let sid = snap.sessionId, let savedLabel = sessionLabels[sid] {
            session.label = savedLabel
        } else if let label = snap.label {
            session.label = label
        }
        session.lastPlanPath = snap.lastPlanPath
        rehydrateYolo(snap, into: session)
        sessions[snap.pid] = session
    }

    /// Restore YOLO state across daemon restarts. If the plan's content drifted
    /// while we were down, disengage on load with a clear reason — preserves the
    /// invariant that an engaged YOLO session always reflects the original plan.
    private func rehydrateYolo(_ snap: PersistedSession, into session: Session) {
        guard let engagedAt = snap.yoloEngagedAt,
              let path = snap.yoloPlanPath,
              let originalHash = snap.yoloPlanHash else {
            session.yoloDisabledReason = snap.yoloDisabledReason
            return
        }
        let currentHash = YoloMode.sha256(ofFileAt: path)
        if currentHash == nil {
            session.yoloDisabledReason = "plan deleted during daemon restart"
            return
        }
        if currentHash != originalHash {
            session.yoloDisabledReason = "plan changed during daemon restart"
            return
        }
        session.yoloEngagedAt = engagedAt
        session.yoloPlanPath = path
        session.yoloPlanHash = originalHash
        session.yoloDisabledReason = snap.yoloDisabledReason
        session.setYoloActive(true)
    }

    private func rehydrateTombstone(_ snap: PersistedSession, sessionId: String) {
        let session = Session(pid: snap.pid, cwd: snap.cwd, startedAt: snap.endedAt ?? Date(), agent: snap.agent ?? .claude)
        session.sessionId = sessionId
        session.isAlive = false
        session.endedAt = snap.endedAt ?? Date()
        if let savedLabel = sessionLabels[sessionId] {
            session.label = savedLabel
        } else if let label = snap.label {
            session.label = label
        }
        deadSessions[sessionId] = session
    }

    /// Find Claude Code CLI processes running on this machine and add any we
    /// don't already track. Solves the "started while gavel was down" gap that
    /// persistence alone can't cover. Discovered sessions get a PID and cwd
    /// immediately; their sessionId is filled in by the next hook event.
    @discardableResult
    func discoverRunningSessions() -> Int {
        let discovered = ProcessTree.findClaudeCliSessions()
        var added = 0
        lock.lock()
        for (pid, cwd) in discovered {
            let pidInt = Int(pid)
            if sessions[pidInt] != nil { continue }
            let started = ProcessTree.startTime(of: pid)
            let session = Session(pid: pidInt, cwd: cwd, startedAt: started)
            session.isAutoApproveEnabled = defaultAutoApprove
            session.isSubAgentInheritEnabled = defaultSubAgentInherit
            session.isPaused = defaultPaused
            sessions[pidInt] = session
            added += 1
        }
        if added > 0 { saveActiveSessionsLocked() }
        lock.unlock()
        return added
    }

    /// Check if a PID is still alive using kill(0).
    func isProcessAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    // MARK: - Cleanup

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = GavelConstants.sessionCleanupInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.cleanupDeadSessions()
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// Internal so tests can drive lifecycle without waiting on the timer.
    func cleanupDeadSessions() {
        lock.lock()
        let pids = Array(sessions.keys)
        lock.unlock()
        for pid in pids {
            guard !isProcessAlive(pid: pid) else { continue }
            lock.lock()
            guard let session = sessions[pid] else {
                lock.unlock()
                continue
            }
            let now = Date()
            sessions.removeValue(forKey: pid)
            if let sid = session.sessionId {
                deadSessions[sid] = session
            }
            saveActiveSessionsLocked()
            lock.unlock()
            // @Published mutations need main thread; this runs on a utility queue.
            DispatchQueue.main.async {
                session.isAlive = false
                session.endedAt = now
            }
        }
    }

    // MARK: - Bulk prompt mode

    /// Revokes auto-approval on every active session and clears global defaults.
    /// Called by the "Prompt All Sessions" menu item, the per-session Prompt button
    /// (for its own session only — this is the fan-out variant), and the inactivity timer.
    func promptAllSessions(reason: String = "Prompt All") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for session in self.sessions.values {
                session.revokeAutoApprove()
            }
            self.defaultAutoApprove = false
            self.defaultSubAgentInherit = false
            self.saveDefaults()
            // Persist the per-session revoke too so an inactivity-driven flip
            // (or "Prompt All" click) survives a daemon restart. Otherwise
            // the user wakes up to gavel restoring the OLD auto state.
            self.saveActiveSessions()
            GavelNotifications.notify(title: "Gavel — Prompt Mode", body: reason)
            self.noteInteraction()
        }
    }

    // MARK: - Inactivity

    /// Records the user's most recent interaction with gavel. Resets the inactivity timer.
    func noteInteraction() {
        lock.lock()
        lastInteraction = Date()
        lock.unlock()
    }

    private func startInactivityTimer() {
        // Check once per minute. Cheaper than per-second and good enough for a
        // threshold measured in minutes.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.checkInactivity()
        }
        timer.resume()
        inactivityTimer = timer
    }

    private func checkInactivity() {
        let minutes = inactivityTimeoutMinutes
        guard minutes > 0 else { return }

        lock.lock()
        let idle = Date().timeIntervalSince(lastInteraction)
        lock.unlock()

        guard idle >= Double(minutes) * 60 else { return }

        // Only fire if anything is currently auto-approving — no point nagging otherwise.
        let anyAuto = defaultAutoApprove
            || sessions.values.contains { $0.isAutoApproveEnabled || $0.isAutoApproveActive || $0.isSubAgentInheritEnabled }
        guard anyAuto else { return }

        promptAllSessions(reason: "Auto-approval disabled after \(minutes) min idle")
    }
}
