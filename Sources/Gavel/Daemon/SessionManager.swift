import Foundation

/// Manages all active Claude Code sessions.
///
/// Sessions are keyed by PID. The manager periodically checks for
/// dead processes and cleans up their state.
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Int: Session] = [:]

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

    private static var defaultsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/gavel/session-defaults.json"
    }

    private static var sessionsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/gavel/active-sessions.json"
    }

    init() {
        loadDefaults()
        loadActiveSessions()
        discoverRunningSessions()
        startCleanupTimer()
        startInactivityTimer()
    }

    deinit {
        cleanupTimer?.cancel()
        inactivityTimer?.cancel()
    }

    /// Get or create a session for the given PID.
    /// New sessions inherit the default Auto/Sub settings.
    func session(for pid: Int) -> Session {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[pid] {
            return existing
        }
        let session = Session(pid: pid)
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
            FileManager.default.createFile(atPath: Self.defaultsPath, contents: json)
        }
    }

    private func loadDefaults() {
        guard let data = FileManager.default.contents(atPath: Self.defaultsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        defaultAutoApprove = (json["autoApprove"] as? Bool) ?? false
        defaultSubAgentInherit = (json["subAgentInherit"] as? Bool) ?? false
        defaultPaused = (json["paused"] as? Bool) ?? false
        inactivityTimeoutMinutes = (json["inactivityTimeoutMinutes"] as? Int) ?? 15
        sessionLabels = (json["sessionLabels"] as? [String: String]) ?? [:]
    }

    /// Bind a Claude Code session UUID to a Session and apply any saved label.
    /// If the user typed a label before the sessionId was known, persist it now.
    func recordSessionId(_ sid: String, on session: Session) {
        let changed = session.sessionId != sid
        session.sessionId = sid
        if session.label.isEmpty, let saved = sessionLabels[sid] {
            session.label = saved
        } else if !session.label.isEmpty && sessionLabels[sid] != session.label {
            sessionLabels[sid] = session.label
            saveDefaults()
        }
        if changed {
            lock.lock()
            saveActiveSessionsLocked()
            lock.unlock()
        }
    }

    /// Update the cwd for a session and persist the change.
    func recordCwd(_ cwd: String, on session: Session) {
        let changed = session.cwd != cwd
        session.cwd = cwd
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

    /// Remove a session (e.g., when the process exits).
    func removeSession(pid: Int) {
        lock.lock()
        sessions.removeValue(forKey: pid)
        saveActiveSessionsLocked()
        lock.unlock()
    }

    /// Drop any sessions whose process has exited. Triggered by the "Clear Dead"
    /// monitor button so the user doesn't have to wait for the cleanup timer's
    /// grace period.
    func clearDeadSessions() {
        lock.lock()
        let toRemove = sessions.compactMap { (pid, session) -> Int? in
            (!session.isAlive || !isProcessAlive(pid: pid)) ? pid : nil
        }
        for pid in toRemove {
            sessions.removeValue(forKey: pid)
        }
        if !toRemove.isEmpty {
            saveActiveSessionsLocked()
        }
        lock.unlock()
    }

    // MARK: - Active session persistence

    /// Snapshot of a live session, persisted to active-sessions.json so the
    /// daemon can rehydrate per-session toggle state across restarts/crashes.
    /// New fields (auto/sub/paused) are optional so older on-disk files
    /// load cleanly — missing values fall through to defaults.
    private struct PersistedSession: Codable {
        let pid: Int
        let sessionId: String?
        let cwd: String?
        let isAutoApproveEnabled: Bool?
        let isSubAgentInheritEnabled: Bool?
        let isPaused: Bool?
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
        let snapshot = sessions.values
            .filter { $0.isAlive }
            .map { PersistedSession(
                pid: $0.pid,
                sessionId: $0.sessionId,
                cwd: $0.cwd,
                isAutoApproveEnabled: $0.isAutoApproveEnabled,
                isSubAgentInheritEnabled: $0.isSubAgentInheritEnabled,
                isPaused: $0.isPaused
            ) }
        guard let json = try? JSONEncoder().encode(snapshot) else { return }
        FileManager.default.createFile(atPath: Self.sessionsPath, contents: json)
    }

    /// Rehydrate sessions seen by the daemon before restart. Filters out PIDs
    /// whose process is no longer alive. Must run after loadDefaults() so that
    /// labels are already populated and can be applied here.
    private func loadActiveSessions() {
        guard let data = FileManager.default.contents(atPath: Self.sessionsPath),
              let snapshots = try? JSONDecoder().decode([PersistedSession].self, from: data) else { return }

        for snap in snapshots {
            guard isProcessAlive(pid: snap.pid) else { continue }
            let started = ProcessTree.startTime(of: Int32(snap.pid))
            let session = Session(pid: snap.pid, cwd: snap.cwd, startedAt: started)
            session.sessionId = snap.sessionId
            // Apply persisted per-session settings if present, else fall back
            // to defaults (covers older on-disk files written before this
            // field set existed).
            session.isAutoApproveEnabled = snap.isAutoApproveEnabled ?? defaultAutoApprove
            session.isSubAgentInheritEnabled = snap.isSubAgentInheritEnabled ?? defaultSubAgentInherit
            session.isPaused = snap.isPaused ?? defaultPaused
            if let sid = snap.sessionId, let savedLabel = sessionLabels[sid] {
                session.label = savedLabel
            }
            sessions[snap.pid] = session
        }
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

    private func cleanupDeadSessions() {
        lock.lock()
        let pids = Array(sessions.keys)
        lock.unlock()
        for pid in pids {
            if !isProcessAlive(pid: pid) {
                lock.lock()
                sessions[pid]?.isAlive = false
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + GavelConstants.sessionRemovalGraceSeconds) { [weak self] in
                    self?.removeSession(pid: pid)
                }
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
