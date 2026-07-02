import CryptoKit
import Foundation

/// Append-only, tamper-evident journal of rule mutations (rules-audit.jsonl).
///
/// Every authorized change to rules.json — panel adds/edits/deletes, approval-panel
/// "Always allow/deny", accepted/rejected Claude proposals — appends one JSON line.
/// Each entry carries `prev` (the previous entry's hash) and `hash` (SHA-256 over the
/// entry's own canonical JSON), forming a chain: rewriting or deleting a historical
/// line breaks every hash after it, so tampering is detectable via `verifyChain()`
/// even by a reader who only trusts the latest entry.
final class RuleAuditLog {
    struct Entry: Codable {
        let seq: Int
        let ts: Date
        let action: String
        let origin: String
        let toolName: String
        let pattern: String
        let verdict: String
        let detail: String?
        var prev: String
        var hash: String
    }

    static let genesisHash = String(repeating: "0", count: 64)

    private let path: String
    private let lock = NSLock()
    private var lastHash: String
    private var lastSeq: Int

    init(path: String) {
        self.path = path
        (lastSeq, lastHash) = Self.readTail(path: path)
    }

    var filePath: String { path }

    func record(action: String, origin: String, toolName: String, pattern: String, verdict: String, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var entry = Entry(
            seq: lastSeq + 1, ts: Date(), action: action, origin: origin,
            toolName: toolName, pattern: pattern, verdict: verdict, detail: detail,
            prev: lastHash, hash: ""
        )
        entry.hash = Self.computeHash(entry)

        guard let line = Self.encodeLine(entry) else {
            gavelLog("RuleAuditLog: failed to encode entry seq=\(entry.seq)")
            return
        }
        append(line: line)
        lastSeq = entry.seq
        lastHash = entry.hash
    }

    /// Recompute the full chain. Returns the first broken sequence number, or nil if intact.
    func verifyChain() -> Int? {
        lock.lock()
        defer { lock.unlock() }

        var prev = Self.genesisHash
        for entry in Self.readEntries(path: path) {
            if entry.prev != prev || Self.computeHash(entry) != entry.hash {
                return entry.seq
            }
            prev = entry.hash
        }
        return nil
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Self.readEntries(path: path)
    }

    // MARK: - Hashing / encoding

    /// Hash over the canonical (sorted-keys) JSON of the entry with `hash` zeroed,
    /// so encoder field order can never affect chain validity.
    private static func computeHash(_ entry: Entry) -> String {
        var unhashed = entry
        unhashed.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(unhashed) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeLine(_ entry: Entry) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func readEntries(path: String) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Entry.self, from: Data(line.utf8))
        }
    }

    private static func readTail(path: String) -> (seq: Int, hash: String) {
        guard let last = readEntries(path: path).last else { return (0, genesisHash) }
        return (last.seq, last.hash)
    }

    private func append(line: Data) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            gavelLog("RuleAuditLog: cannot open \(path) for append")
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }
}
