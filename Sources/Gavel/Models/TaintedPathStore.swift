import Foundation

/// Lock-protected set of paths tainted by sensitive data. Same threading rationale as `SessionStats`: TaintTracker writes from workers on every Bash/Write/Edit hook; @Published would deadlock under load.
final class TaintedPathStore {
    private let lock = NSLock()
    private var _paths = Set<String>()

    /// Atomic copy — caller can iterate without holding the lock.
    var snapshot: Set<String> { lock.lock(); defer { lock.unlock() }; return _paths }

    func insert(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _paths.insert(path)
    }

    func formUnion(_ paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _paths.formUnion(paths)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return _paths.count }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return _paths.isEmpty }
    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _paths.contains(path)
    }
    func sorted() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths.sorted()
    }
}
