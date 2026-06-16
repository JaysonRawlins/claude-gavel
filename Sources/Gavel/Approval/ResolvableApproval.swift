import Foundation

/// Idempotent resolution guard for an approval that two responders race for
/// (the on-Mac panel and the Telegram bridge). Exactly one `resolve` wins.
final class ResolvableApproval {

    enum Source { case mac, telegram, timeout, autoApprove }

    private let lock = NSLock()
    private var resolved = false
    private let sink: (Decision) -> Void
    private var onResolved: [(Source, Decision) -> Void] = []

    init(sink: @escaping (Decision) -> Void) {
        self.sink = sink
    }

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    /// Register a one-shot cleanup hook. Skipped if already resolved.
    func addCleanup(_ hook: @escaping (Source, Decision) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        onResolved.append(hook)
    }

    /// Returns true iff this call won the race. The sink and every cleanup hook
    /// fire exactly once, on the winning caller's thread.
    @discardableResult
    func resolve(_ decision: Decision, from source: Source) -> Bool {
        lock.lock()
        if resolved {
            lock.unlock()
            return false
        }
        resolved = true
        let hooks = onResolved
        onResolved = []
        lock.unlock()

        sink(decision)
        for hook in hooks { hook(source, decision) }
        return true
    }
}
