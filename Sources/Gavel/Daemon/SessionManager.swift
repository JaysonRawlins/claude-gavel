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

    @Published var defaultRemoteApprove: Bool = false

    /// Fired after an emergency phone-stop with the count of sessions that had phone on.
    var onPhoneStopped: ((_ affected: Int) -> Void)?

    /// Inactivity threshold in minutes. 0 disables the timer.
    /// When the user hasn't interacted with gavel for this long, auto-approval
    /// is revoked across all sessions (walk-away defense).
    @Published var inactivityTimeoutMinutes: Int = 15

    /// Pinned Telegram chat id for remote approval. Not secret; the bot token
    /// lives in Keychain. Nil until paired via `/start`.
    @Published var telegramChatId: Int64?

    /// User-typed labels keyed by Claude Code session UUID. Survives daemon restarts.
    @Published private var sessionLabels: [String: String] = [:]

    private var jsonlSeedTriedPids: Set<Int> = []
    private var watchers: [Int: JsonlWatcher] = [:]

    private var lastInteraction: Date = Date()

    /// Fired on session create / tombstone / discover; the daemon mirrors it to gavel.log + the Feed.
    var onLifecycle: ((_ message: String, _ pid: Int, _ at: Date) -> Void)?

    private let defaultsPath: String
    private let sessionsPath: String

    init(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        autoStartTimers: Bool = true,
        autoDiscover: Bool = true,
        liveness: @escaping (Int, String?) -> Bool = SessionManager.defaultLiveness
    ) {
        let base = homeDir.path + "/.claude/gavel"
        self.defaultsPath = base + "/session-defaults.json"
        self.sessionsPath = base + "/active-sessions.json"
        self.livenessCheck = liveness
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
        if let existing = sessions[pid] {
            lock.unlock()
            return existing
        }
        let session = Session(pid: pid, agent: agent)
        session.isAutoApproveEnabled = defaultAutoApprove
        session.isSubAgentInheritEnabled = defaultSubAgentInherit
        session.isPaused = defaultPaused
        if defaultRemoteApprove && telegramChatId != nil {
            session.setRemoteApprovalEnabled(true, until: nil)
        }
        sessions[pid] = session
        saveActiveSessionsLocked()
        lock.unlock()
        noteLifecycle("session appeared (\(agent.rawValue))", pid: pid)
        return session
    }

    // Call outside `lock` — does file IO and forwards to a main-thread sink.
    private func noteLifecycle(_ message: String, pid: Int, at: Date = Date()) {
        gavelLog("[session] \(message) pid=\(pid)")
        onLifecycle?(message, pid, at)
    }

    /// Save current defaults to disk (called when user toggles).
    func saveDefaults() {
        var data: [String: Any] = [
            "autoApprove": defaultAutoApprove,
            "subAgentInherit": defaultSubAgentInherit,
            "paused": defaultPaused,
            "remoteApprove": defaultRemoteApprove,
            "inactivityTimeoutMinutes": inactivityTimeoutMinutes,
            "sessionLabels": sessionLabels
        ]
        if let chatId = telegramChatId { data["telegramChatId"] = chatId }
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
        defaultRemoteApprove = (json["remoteApprove"] as? Bool) ?? false
        inactivityTimeoutMinutes = (json["inactivityTimeoutMinutes"] as? Int) ?? 15
        sessionLabels = (json["sessionLabels"] as? [String: String]) ?? [:]
        telegramChatId = (json["telegramChatId"] as? Int64) ?? (json["telegramChatId"] as? Int).map(Int64.init)
    }

    /// Worker-thread caller; @Published mutations dispatched to main.
    /// A matching tombstone is dropped — same conversation, new PID.
    func recordSessionId(_ sid: String, on session: Session) {
        let changed = session.sessionId != sid
        let savedLabel = sessionLabels[sid]
        let currentLabel = session.label
        DispatchQueue.main.async { [weak self] in
            session.sessionId = sid
            if session.label.isEmpty, let saved = savedLabel {
                session.label = saved
            }
            self?.tryJsonlSeed(session: session)
        }
        if !currentLabel.isEmpty && !session.labelIsDerived && savedLabel != currentLabel {
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
        DispatchQueue.main.async { [weak self] in
            session.cwd = cwd
            self?.tryJsonlSeed(session: session)
        }
        if changed {
            lock.lock()
            saveActiveSessionsLocked()
            lock.unlock()
        }
    }

    private func tryJsonlSeed(session: Session) {
        startWatcherIfReady(for: session)
        guard session.label.isEmpty, !jsonlSeedTriedPids.contains(session.pid) else { return }
        guard let sid = session.sessionId, let cwd = session.cwd else { return }
        jsonlSeedTriedPids.insert(session.pid)
        if let seeded = JsonlRenameReader.latestRename(cwd: cwd, sessionId: sid) {
            session.labelIsDerived = false
            session.label = seeded
            setLabel(seeded, for: sid)
            return
        }
        guard let derived = JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid) else { return }
        session.labelIsDerived = true
        session.label = derived
        saveActiveSessions()
    }

    /// Apply an externally-sourced label update (e.g., from JSONL watcher); no-op on empty or unchanged input.
    func updateLabel(_ newLabel: String, on session: Session, sessionId: String? = nil) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let currentLabel = session.label
        guard currentLabel != trimmed else { return }
        DispatchQueue.main.async {
            session.labelIsDerived = false
            session.label = trimmed
        }
        if let sid = sessionId ?? session.sessionId {
            sessionLabels[sid] = trimmed
            saveDefaults()
        }
        saveActiveSessions()
    }

    private func startWatcherIfReady(for session: Session) {
        guard watchers[session.pid] == nil else { return }
        guard let sid = session.sessionId, let cwd = session.cwd else { return }
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects")
            .appending("/\(encoded)/\(sid).jsonl")
        let handlers: [JsonlEventHandler] = [RenameHandler(), SecretHandler(), SkillTagHandler(), StopPhoneHandler()]
        let dispatcher = JsonlEventDispatcher(handlers: handlers, manager: self, session: session)
        let watcher = JsonlWatcher(path: path, dispatcher: dispatcher)
        watchers[session.pid] = watcher
        watcher.start()
    }

    private func stopWatcher(forPid pid: Int) {
        guard let watcher = watchers.removeValue(forKey: pid) else { return }
        watcher.stop()
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

    /// Re-derive a name for every still-blank session (live or asleep) by re-reading its transcript; catches sessions that were empty when first seen but have since produced a first prompt, which the one-shot seed guard never retries.
    @discardableResult
    func nameUnnamedSessions() -> Int {
        lock.lock()
        let candidates = (Array(sessions.values) + Array(deadSessions.values)).filter { $0.label.isEmpty }
        lock.unlock()

        var named = 0
        var explicitLabelsChanged = false
        for session in candidates {
            guard let sid = session.sessionId, let cwd = session.cwd else { continue }
            if let renamed = JsonlRenameReader.latestRename(cwd: cwd, sessionId: sid) {
                session.labelIsDerived = false
                session.label = renamed
                sessionLabels[sid] = renamed
                explicitLabelsChanged = true
                named += 1
            } else if let derived = JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid) {
                session.labelIsDerived = true
                session.label = derived
                named += 1
            }
        }
        if named > 0 { saveActiveSessions() }
        if explicitLabelsChanged { saveDefaults() }
        return named
    }

    func clearDeadSessions() {
        lock.lock()
        let strayPids = sessions.compactMap { (pid, session) -> Int? in
            (!session.isAlive || !isProcessAlive(pid: pid, cwd: session.cwd)) ? pid : nil
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
        let labelIsDerived: Bool?
        let endedAt: Date?
        let agent: AgentKind?
        let isRemoteApprovalEnabled: Bool?
        let remoteApprovalUntil: Date?
        let tags: [SessionTag]?
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
            labelIsDerived: session.labelIsDerived ? true : nil,
            endedAt: session.endedAt,
            agent: session.agent,
            isRemoteApprovalEnabled: session.remoteApprovalSnapshot.enabled ? true : nil,
            remoteApprovalUntil: session.remoteApprovalSnapshot.until,
            tags: session.tags.isEmpty ? nil : session.tags.snapshot
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
            if isProcessAlive(pid: snap.pid, cwd: snap.cwd) {
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
            session.labelIsDerived = snap.labelIsDerived ?? false
        }
        if snap.isRemoteApprovalEnabled == true,
           snap.remoteApprovalUntil == nil || (snap.remoteApprovalUntil.map { $0 > Date() } ?? true) {
            session.setRemoteApprovalEnabled(true, until: snap.remoteApprovalUntil)
        }
        session.tags.load(snap.tags ?? [])
        sessions[snap.pid] = session
        tryJsonlSeed(session: session)
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
            session.labelIsDerived = snap.labelIsDerived ?? false
        } else if let cwd = snap.cwd,
                  let derived = JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sessionId) {
            session.label = derived
            session.labelIsDerived = true
        }
        session.tags.load(snap.tags ?? [])
        deadSessions[sessionId] = session
    }

    /// Find Claude Code CLI processes running on this machine and add any we
    /// don't already track. Solves the "started while gavel was down" gap that
    /// persistence alone can't cover. Discovered sessions get a PID and cwd
    /// immediately; their sessionId is filled in by the next hook event.
    @discardableResult
    func discoverRunningSessions() -> Int {
        let discovered = ProcessTree.findClaudeCliSessions()
        var addedPids: [Int] = []
        lock.lock()
        for (pid, cwd) in discovered {
            let pidInt = Int(pid)
            if sessions[pidInt] != nil { continue }
            let started = ProcessTree.startTime(of: pid)
            let session = Session(pid: pidInt, cwd: cwd, startedAt: started)
            session.isAutoApproveEnabled = defaultAutoApprove
            session.isSubAgentInheritEnabled = defaultSubAgentInherit
            session.isPaused = defaultPaused
            if defaultRemoteApprove && telegramChatId != nil {
                session.setRemoteApprovalEnabled(true, until: nil)
            }
            sessions[pidInt] = session
            addedPids.append(pidInt)
        }
        if !addedPids.isEmpty { saveActiveSessionsLocked() }
        lock.unlock()
        for pid in addedPids { noteLifecycle("session discovered (already running)", pid: pid) }
        return addedPids.count
    }

    /// Liveness predicate for a tracked PID; overridable so tests can fake a live session.
    var livenessCheck: (Int, String?) -> Bool

    func isProcessAlive(pid: Int, cwd: String?) -> Bool {
        livenessCheck(pid, cwd)
    }

    // Match on cwd, not p_comm: Claude Code reports its version string (e.g. "2.1.158")
    // as p_comm, so a recycled PID can't be ruled out by process name.
    static func defaultLiveness(pid: Int, cwd expectedCwd: String?) -> Bool {
        guard kill(Int32(pid), 0) == 0 || errno == EPERM else { return false }
        guard let expectedCwd else { return true }
        guard let actual = ProcessTree.cwd(of: Int32(pid)) else { return false }
        return actual == expectedCwd
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
            lock.lock()
            let cwd = sessions[pid]?.cwd
            lock.unlock()
            guard !isProcessAlive(pid: pid, cwd: cwd) else { continue }
            lock.lock()
            guard let session = sessions[pid] else {
                lock.unlock()
                continue
            }
            let now = Date()
            let resumable = session.sessionId != nil
            sessions.removeValue(forKey: pid)
            if let sid = session.sessionId {
                deadSessions[sid] = session
            }
            saveActiveSessionsLocked()
            lock.unlock()
            stopWatcher(forPid: pid)
            noteLifecycle(resumable ? "session asleep (process exited)" : "session disappeared (process exited)", pid: pid, at: now)
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
                session.disableRemoteApproval()
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

    /// Emergency hatch: disables phone approval on every live session and clears Default Phone.
    func stopAllPhone(reason: String = "stop-phone") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let affected = self.sessions.values.filter { $0.remoteApprovalSnapshot.enabled }.count
            for session in self.sessions.values { session.disableRemoteApproval() }
            self.defaultRemoteApprove = false
            self.saveDefaults()
            self.saveActiveSessions()
            gavelLog("[stop-phone] \(reason) — disabled phone on \(affected) session(s), default off")
            GavelNotifications.notify(title: "Gavel — Phone OFF", body: reason)
            self.noteInteraction()
            self.onPhoneStopped?(affected)
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
