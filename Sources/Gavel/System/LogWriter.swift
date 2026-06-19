import Foundation

/// Serializes log-line appends to one file so concurrent writers can't drop or tear lines.
final class LogWriter {
    private let path: String
    private let lock = NSLock()

    init(path: String) {
        self.path = path
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

let gavelLogWriter = LogWriter(
    path: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/gavel/gavel.log").path
)
