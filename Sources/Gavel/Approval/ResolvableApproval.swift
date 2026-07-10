import Foundation

/// Idempotent resolution guard for an approval that two responders race for
/// (the on-Mac panel and the Telegram bridge). Exactly one `resolve` wins.
final class ResolvableApproval {

    enum Source { case mac, telegram, timeout, autoApprove, web }

    private let lock = NSLock()
    private var resolved = false
    /// Hands the winning Decision back to the blocked approval worker — the
    /// closure `requestApproval` passes in to capture the result and signal
    /// its semaphore.
    private let deliverDecision: (Decision) -> Void
    private var onResolved: [(Source, Decision) -> Void] = []
    private var transforms: [(Decision, Source) -> Decision] = []

    init(deliverDecision: @escaping (Decision) -> Void) {
        self.deliverDecision = deliverDecision
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

    /// Register a transform applied to the winning Decision before it is
    /// delivered — this is how state known only to one responder (e.g. the
    /// review page was opened) can decorate a resolution won by a different
    /// responder. Skipped if already resolved.
    func addDecisionTransform(_ transform: @escaping (Decision, Source) -> Decision) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        transforms.append(transform)
    }

    /// Returns true iff this call won the race. The decision is delivered and
    /// every cleanup hook fires exactly once, on the winning caller's thread.
    @discardableResult
    func resolve(_ decision: Decision, from source: Source) -> Bool {
        lock.lock()
        if resolved {
            lock.unlock()
            return false
        }
        resolved = true
        let hooks = onResolved
        let pendingTransforms = transforms
        onResolved = []
        transforms = []
        lock.unlock()

        let final = pendingTransforms.reduce(decision) { $1($0, source) }
        deliverDecision(final)
        for hook in hooks { hook(source, final) }
        return true
    }
}
