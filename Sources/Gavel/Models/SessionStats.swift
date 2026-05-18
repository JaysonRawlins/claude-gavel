import Foundation

/// Lock-protected counters mutated from worker threads. NOT @Published — background-thread @Published writes deadlocked workers post-accept() under load. UI reads via MonitorViewModel's 2s timer that calls `objectWillChange.send()`.
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
