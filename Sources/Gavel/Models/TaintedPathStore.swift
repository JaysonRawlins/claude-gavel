import Foundation

/// Thread-safe set of paths the daemon has flagged as tainted by sensitive
/// data flow. Same threading rationale as `SessionStats`: TaintTracker reads
/// and writes this from worker threads on every Bash and Write/Edit hook;
/// `@Published Set<String>` mutations from background would deadlock with
/// SwiftUI's publish chain under load.
///
/// The "snapshot" name on the read accessor is intentional — the returned
/// `Set<String>` is a copy, not a live view, so callers can iterate without
/// holding the lock. Set-like conveniences (`count`, `isEmpty`, `sorted()`,
/// `contains`) are provided so existing UI code (`session.taintedPaths.count`)
/// continues to read naturally.
final class TaintedPathStore {
    private let lock = NSLock()
    private var _paths = Set<String>()

    /// Atomic snapshot of the current set. Safe to iterate from any thread.
    var snapshot: Set<String> { lock.lock(); defer { lock.unlock() }; return _paths }

    func insert(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _paths.insert(path)
    }

    func formUnion(_ paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _paths.formUnion(paths)
    }

    // MARK: - Set-shaped conveniences for UI / read-side callers

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
