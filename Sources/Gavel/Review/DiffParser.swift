import Foundation

/// One file's worth of a unified diff.
struct DiffFile {
    var oldPath: String = ""
    var newPath: String = ""
    var isNew = false
    var isDeleted = false
    var isRename = false
    var isBinary = false
    var hunks: [DiffHunk] = []

    var displayPath: String {
        if newPath.isEmpty || newPath == "/dev/null" { return oldPath }
        return newPath
    }

    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
}

struct DiffHunk {
    let header: String
    /// First new-file line of the hunk — the anchor for review comments.
    let newStart: Int
    var lines: [DiffLine] = []

    /// Raw hunk text, scanned for credentials before the hunk is served.
    var rawText: String {
        ([header] + lines.map { $0.raw }).joined(separator: "\n")
    }
}

struct DiffLine {
    enum Kind { case context, addition, deletion, meta }
    let kind: Kind
    /// Full line including the +/-/space prefix.
    let raw: String
    let oldNumber: Int?
    let newNumber: Int?
}

/// Parses `git diff` unified output into `DiffFile`s. Best-effort: unrecognized
/// metadata lines are skipped, paths with spaces resolve via the ---/+++ lines.
enum DiffParser {

    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldNo = 0
        var newNo = 0

        func flushHunk() {
            if let h = hunk, let _ = file { file!.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if rawLines.last == "" { rawLines.removeLast() }

        for s in rawLines {

            if s.hasPrefix("diff --git ") {
                flushFile()
                var f = DiffFile()
                // "diff --git a/x b/y" — ambiguous when paths contain spaces;
                // the ---/+++ lines below overwrite with authoritative values.
                if let range = s.range(of: " b/", options: .backwards) {
                    f.newPath = String(s[range.upperBound...])
                    let head = String(s[s.index(s.startIndex, offsetBy: 11)..<range.lowerBound])
                    f.oldPath = head.hasPrefix("a/") ? String(head.dropFirst(2)) : head
                }
                file = f
                continue
            }

            guard file != nil else { continue }

            if hunk == nil {
                if s.hasPrefix("new file mode") { file!.isNew = true; continue }
                if s.hasPrefix("deleted file mode") { file!.isDeleted = true; continue }
                if s.hasPrefix("rename from ") {
                    file!.isRename = true
                    file!.oldPath = String(s.dropFirst("rename from ".count))
                    continue
                }
                if s.hasPrefix("rename to ") {
                    file!.newPath = String(s.dropFirst("rename to ".count))
                    continue
                }
                if s.hasPrefix("Binary files ") || s.hasPrefix("GIT binary patch") {
                    file!.isBinary = true
                    continue
                }
                if s.hasPrefix("--- ") {
                    let p = String(s.dropFirst(4))
                    file!.oldPath = p.hasPrefix("a/") ? String(p.dropFirst(2)) : p
                    continue
                }
                if s.hasPrefix("+++ ") {
                    let p = String(s.dropFirst(4))
                    file!.newPath = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
                    continue
                }
            }

            if s.hasPrefix("@@") {
                flushHunk()
                let (o, n) = Self.hunkStarts(s)
                oldNo = o
                newNo = n
                hunk = DiffHunk(header: s, newStart: n)
                continue
            }

            guard hunk != nil else { continue }

            if s.hasPrefix("+") {
                hunk!.lines.append(DiffLine(kind: .addition, raw: s, oldNumber: nil, newNumber: newNo))
                newNo += 1
            } else if s.hasPrefix("-") {
                hunk!.lines.append(DiffLine(kind: .deletion, raw: s, oldNumber: oldNo, newNumber: nil))
                oldNo += 1
            } else if s.hasPrefix("\\") {
                hunk!.lines.append(DiffLine(kind: .meta, raw: s, oldNumber: nil, newNumber: nil))
            } else {
                hunk!.lines.append(DiffLine(kind: .context, raw: s, oldNumber: oldNo, newNumber: newNo))
                oldNo += 1
                newNo += 1
            }
        }
        flushFile()
        return files
    }

    /// Extracts (oldStart, newStart) from "@@ -12,5 +14,6 @@ context".
    static func hunkStarts(_ header: String) -> (Int, Int) {
        var old = 0
        var new = 0
        for token in header.split(separator: " ") {
            if token.hasPrefix("-") {
                old = Int(token.dropFirst().split(separator: ",").first ?? "0") ?? 0
            } else if token.hasPrefix("+") {
                new = Int(token.dropFirst().split(separator: ",").first ?? "0") ?? 0
            }
        }
        return (old, new)
    }
}
