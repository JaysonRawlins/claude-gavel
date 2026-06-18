import Foundation

final class JsonlWatcher {
    private let path: String
    private let dispatcher: JsonlEventDispatcher
    private let queue: DispatchQueue

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastOffset: UInt64 = 0
    private var lineBuffer = Data()

    init(path: String, dispatcher: JsonlEventDispatcher) {
        self.path = path
        self.dispatcher = dispatcher
        self.queue = DispatchQueue(
            label: "gavel.jsonl-watcher.\(UUID().uuidString.prefix(8))",
            qos: .utility
        )
    }

    func start() {
        queue.async { [weak self] in
            self?.openAndSubscribe()
            self?.startPoll()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
            self?.tearDown()
        }
    }

    private func startPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollOnce() }
        timer.resume()
        pollTimer = timer
    }

    private func pollOnce() {
        guard fileHandle != nil else {
            openAndSubscribe()
            return
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value, size < lastOffset {
            reopenAfterRotation()
            return
        }
        readNewBytes()
    }

    private func openAndSubscribe() {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openAndSubscribe()
            }
            return
        }
        fileHandle = handle
        lastOffset = handle.seekToEndOfFile()
        lineBuffer.removeAll()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.handleFsEvent() }
        src.resume()
        source = src
    }

    private func handleFsEvent() {
        guard let source = source else { return }
        let mask = source.data
        if mask.contains(.delete) || mask.contains(.rename) {
            reopenAfterRotation()
            return
        }
        if mask.contains(.write) {
            readNewBytes()
        }
    }

    private func reopenAfterRotation() {
        tearDown()
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openAndSubscribe()
        }
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func readNewBytes() {
        guard let handle = fileHandle else { return }
        let currentEnd = handle.seekToEndOfFile()
        guard currentEnd > lastOffset else { return }
        try? handle.seek(toOffset: lastOffset)
        let newData = handle.readData(ofLength: Int(currentEnd - lastOffset))
        lastOffset = currentEnd

        lineBuffer.append(newData)
        while let nlIdx = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: 0..<nlIdx)
            lineBuffer.removeSubrange(0...nlIdx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                dispatcher.dispatch(line)
            }
        }
    }
}
