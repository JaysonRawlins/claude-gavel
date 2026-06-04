import Foundation

/// Tier-1 filesystem integrity enforcement for Gavel's own config.
///
/// Sets the user-immutable flag (`UF_IMMUTABLE`, i.e. `chflags uchg`) on the
/// security-critical config so a write by any process — including a container
/// bind-mount that bypasses command-string matching — fails with `EPERM` at the
/// host filesystem layer, regardless of which binary or runtime initiated it.
/// The daemon's own saves route through ``withWriteWindow(path:_:)``, which
/// briefly clears the flag.
final class ConfigIntegrity {
    static let shared = ConfigIntegrity()

    private let lock = NSLock()
    private let protectedPaths: Set<String>

    init(protectedPaths: [String]? = nil) {
        let resolved = protectedPaths ?? [Self.defaultRulesPath]
        self.protectedPaths = Set(resolved.map(Self.standardize))
    }

    private static var defaultRulesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/gavel/rules.json"
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Re-assert immutability on every protected path that currently exists.
    func protect() {
        lock.lock()
        defer { lock.unlock() }
        for path in protectedPaths { setImmutable(path, true) }
    }

    /// Clear immutability on every protected path so the files are editable while
    /// the daemon is not running and gating.
    func unprotect() {
        lock.lock()
        defer { lock.unlock() }
        for path in protectedPaths { setImmutable(path, false) }
    }

    /// Run `body` (a write to `path`) with the immutable flag cleared, then
    /// re-assert it. A path outside the protected set runs `body` untouched, so
    /// the temp/`/dev/null` config used in tests is never flagged.
    func withWriteWindow(path: String, _ body: () -> Void) {
        let target = Self.standardize(path)
        guard protectedPaths.contains(target) else {
            body()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        setImmutable(target, false)
        body()
        setImmutable(target, true)
    }

    @discardableResult
    private func setImmutable(_ path: String, _ enable: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let immutable = UInt32(UF_IMMUTABLE)
        let updated = enable ? (info.st_flags | immutable) : (info.st_flags & ~immutable)
        if updated == info.st_flags { return true }
        if chflags(path, updated) == 0 { return true }
        gavelLog("ConfigIntegrity: chflags(\(enable ? "uchg" : "nouchg")) failed for \(path): \(String(cString: strerror(errno)))")
        return false
    }
}
