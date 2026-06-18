import Foundation

enum TagSource: String, Codable {
    case observed
    case manual
}

struct SessionTag: Codable, Hashable {
    let name: String
    let appliedAt: Date
    let source: TagSource
}

final class SessionTagStore {
    private let lock = NSLock()
    private var _tags: [String: SessionTag] = [:]

    var snapshot: [SessionTag] {
        lock.lock(); defer { lock.unlock() }
        return _tags.values.sorted {
            $0.appliedAt == $1.appliedAt ? $0.name < $1.name : $0.appliedAt < $1.appliedAt
        }
    }

    @discardableResult
    func add(_ name: String, at time: Date, source: TagSource) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _tags[name] == nil else { return false }
        _tags[name] = SessionTag(name: name, appliedAt: time, source: source)
        return true
    }

    @discardableResult
    func addObserved(_ name: String, at time: Date) -> Bool {
        add(name, at: time, source: .observed)
    }

    @discardableResult
    func remove(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _tags.removeValue(forKey: name) != nil
    }

    func load(_ tags: [SessionTag]) {
        lock.lock(); defer { lock.unlock() }
        for tag in tags where _tags[tag.name] == nil {
            _tags[tag.name] = tag
        }
    }

    func matches(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let needle = token.lowercased()
        return _tags.keys.contains { $0.lowercased().contains(needle) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return _tags.count }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return _tags.isEmpty }
}
