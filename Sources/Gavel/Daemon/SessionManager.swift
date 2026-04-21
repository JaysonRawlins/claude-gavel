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

    private var lastInteraction: Date = Date()

    private static var defaultsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/gavel/session-defaults.json"
    }

    init() {
        loadDefaults()
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
        return session
    }

    /// Save current defaults to disk (called when user toggles).
    func saveDefaults() {
        let data: [String: Any] = [
            "autoApprove": defaultAutoApprove,
            "subAgentInherit": defaultSubAgentInherit,
            "paused": defaultPaused,
            "inactivityTimeoutMinutes": inactivityTimeoutMinutes
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
    }

    /// Remove a session (e.g., when the process exits).
    func removeSession(pid: Int) {
        lock.lock()
        sessions.removeValue(forKey: pid)
        lock.unlock()
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
