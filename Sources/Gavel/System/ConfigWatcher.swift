import Foundation

/// Tier-2 integrity watcher: detects an out-of-band write to a config file and
/// reverts it from the daemon's in-memory known-good copy, then alerts.
///
/// Complements ``ConfigIntegrity`` (Tier 1): the immutable flag blocks most
/// external writes outright, and this watcher closes the brief clear→write→set
/// window — any change that does land and does not match memory is reverted.
/// The daemon's own saves are ignored automatically because their on-disk bytes
/// match the in-memory re-encoding `isIntact` checks.
final class ConfigWatcher {
    private let path: String
    private let isIntact: () -> Bool
    private let restore: () -> Void
    private let onTamper: () -> Void
    private let queue: DispatchQueue

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?

    init(path: String,
         isIntact: @escaping () -> Bool,
         restore: @escaping () -> Void,
         onTamper: @escaping () -> Void) {
        self.path = path
        self.isIntact = isIntact
        self.restore = restore
        self.onTamper = onTamper
        self.queue = DispatchQueue(label: "gavel.config-watcher", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in self?.openAndSubscribe() }
    }

    func stop() {
        queue.async { [weak self] in self?.tearDown() }
    }

    func evaluateOnce() {
        guard !isIntact() else { return }
        restore()
        onTamper()
    }

    private func openAndSubscribe() {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            evaluateOnce()
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openAndSubscribe() }
            return
        }
        fileHandle = handle

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.handleFsEvent() }
        src.resume()
        source = src

        evaluateOnce()
    }

    private func handleFsEvent() {
        guard let source = source else { return }
        let mask = source.data
        if mask.contains(.delete) || mask.contains(.rename) {
            reopenAfterRotation()
            return
        }
        if mask.contains(.write) {
            evaluateOnce()
        }
    }

    private func reopenAfterRotation() {
        tearDown()
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.openAndSubscribe() }
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }
}
