import XCTest
@testable import Gavel

/// Covers the History-viewer transcript parse: conversational user/assistant
/// text is kept in order; tool/meta/envelope noise is dropped.
final class TranscriptReaderTests: XCTestCase {

    private var writtenPaths: [String] = []

    override func tearDown() {
        for path in writtenPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        writtenPaths.removeAll()
        super.tearDown()
    }

    func testKeepsUserAndAssistantTextInOrder() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":"enable logging on the web ACL"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}"#
        ])
        let messages = TranscriptReader.messages(cwd: cwd, sessionId: sid)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "enable logging on the web ACL")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "On it.")
    }

    func testDropsMetaReminderAndToolNoise() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","isMeta":true,"message":{"content":"injected context"}}"#,
            #"{"type":"user","message":{"content":"<system-reminder>noise</system-reminder>"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"output"}]}}"#,
            #"{"type":"user","message":{"content":"the only real message"}}"#
        ])
        let messages = TranscriptReader.messages(cwd: cwd, sessionId: sid)
        XCTAssertEqual(messages.map(\.text), ["the only real message"])
    }

    func testTruncatesAnOverlongMessage() {
        let huge = String(repeating: "x", count: TranscriptReader.maxMessageLength + 500)
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":"\#(huge)"}}"#
        ])
        let messages = TranscriptReader.messages(cwd: cwd, sessionId: sid)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text.count, TranscriptReader.maxMessageLength + 1, "Truncated body plus the ellipsis")
        XCTAssertTrue(messages[0].text.hasSuffix("…"))
    }

    func testReturnsEmptyWhenTranscriptMissing() {
        let cwd = "/tmp/gavel-transcript-missing-\(UUID().uuidString)"
        XCTAssertTrue(TranscriptReader.messages(cwd: cwd, sessionId: UUID().uuidString).isEmpty)
    }

    private func writeTranscript(lines: [String]) -> (cwd: String, sessionId: String) {
        let cwd = "/tmp/gavel-transcript-test-\(UUID().uuidString)"
        let sid = UUID().uuidString
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects")
            .appending("/\(encoded)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(sid).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        writtenPaths.append(path)
        return (cwd, sid)
    }
}
