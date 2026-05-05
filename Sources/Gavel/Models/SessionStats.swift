import Foundation

/// Thread-safe counters for a single Session. Lives outside the
/// `@ObservedObject` Session class on purpose: every PreToolUse hook
/// increments at least one counter from a worker thread, and `@Published`
/// mutations from background threads tangle with SwiftUI's main-thread
/// publish chain — under load (panel open, multiple concurrent sessions)
/// this manifests as worker-thread deadlocks where new connections accept
/// but never progress past `read()`.
///
/// UI sees updates via `MonitorViewModel.updateStats`, which runs on the
/// 2-second stats timer (main thread) and calls `objectWillChange.send()`
/// on each session — that triggers a SwiftUI re-render which reads the
/// current values via the computed accessors on `Session`. Two-second
/// granularity is fine for monitor stats; nothing here needs millisecond
/// reactivity.
final class SessionStats {
    private let lock = NSLock()
    private var _toolCallCount = 0
    private var _allowCount = 0
    private var _blockCount = 0

    var toolCallCount: Int { lock.lock(); defer { lock.unlock() }; return _toolCallCount }
    var allowCount: Int { lock.lock(); defer { lock.unlock() }; return _allowCount }
    var blockCount: Int { lock.lock(); defer { lock.unlock() }; return _blockCount }

    func incrementToolCall() { lock.lock(); _toolCallCount += 1; lock.unlock() }
    func incrementAllow() { lock.lock(); _allowCount += 1; lock.unlock() }
    func incrementBlock() { lock.lock(); _blockCount += 1; lock.unlock() }
}
