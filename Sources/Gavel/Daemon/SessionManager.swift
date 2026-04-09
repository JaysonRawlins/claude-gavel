import Foundation

/// Manages all active Claude Code sessions.
///
/// Sessions are keyed by PID. The manager periodically checks for
/// dead processes and cleans up their state.
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Int: Session] = [:]

    private let lock = NSLock()
    private let cleanupInterval: TimeInterval = 5.0
    private var cleanupTimer: DispatchSourceTimer?

    init() {
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.cancel()
    }

    /// Get or create a session for the given PID.
    func session(for pid: Int) -> Session {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[pid] {
            return existing
        }
        let session = Session(pid: pid)
        sessions[pid] = session
        return session
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
        timer.schedule(deadline: .now() + cleanupInterval, repeating: cleanupInterval)
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
                // Give a grace period before removal (3 seconds)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.removeSession(pid: pid)
                }
            }
        }
    }
}
