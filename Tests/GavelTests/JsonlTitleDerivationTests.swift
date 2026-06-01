import XCTest
@testable import Gavel

/// Covers the first-prompt title derivation that seeds an auto-name when a
/// session has no explicit `/rename` or `--name` title.
final class JsonlTitleDerivationTests: XCTestCase {

    private var writtenPaths: [String] = []

    override func tearDown() {
        for path in writtenPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        writtenPaths.removeAll()
        super.tearDown()
    }

    func testDerivesTitleFromPlainFirstPrompt() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":"Help me refactor the parser"}}"#
        ])
        XCTAssertEqual(JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid),
                       "Help me refactor the parser")
    }

    func testExtractsTextFromContentParts() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":[{"type":"text","text":"Add a dark mode toggle"}]}}"#
        ])
        XCTAssertEqual(JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid),
                       "Add a dark mode toggle")
    }

    func testSkipsMetaReminderAndToolResultLines() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","isMeta":true,"message":{"content":"injected session context"}}"#,
            #"{"type":"user","message":{"content":"<system-reminder>noise</system-reminder>"}}"#,
            #"{"type":"assistant","message":{"content":"hi"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"output"}]}}"#,
            #"{"type":"user","message":{"content":"The real first question"}}"#
        ])
        XCTAssertEqual(JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid),
                       "The real first question")
    }

    func testTruncatesLongPromptAtWordBoundary() {
        let prompt = "Please investigate why the daemon keeps the old in-memory image after a brew upgrade"
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":"\#(prompt)"}}"#
        ])
        let title = JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasSuffix("…"), "Long prompt should be ellipsized")
        XCTAssertLessThanOrEqual(title!.count, 61, "Title stays near the cap")
        XCTAssertFalse(title!.dropLast().hasSuffix(" "), "Should clip at a word boundary, not mid-space")
    }

    func testReturnsNilWhenNoUsablePrompt() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","isMeta":true,"message":{"content":"only meta"}}"#,
            #"{"type":"assistant","message":{"content":"hi"}}"#
        ])
        XCTAssertNil(JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: sid))
    }

    func testReturnsNilWhenTranscriptMissing() {
        let cwd = "/tmp/gavel-title-missing-\(UUID().uuidString)"
        XCTAssertNil(JsonlRenameReader.firstPromptTitle(cwd: cwd, sessionId: UUID().uuidString))
    }

    func testUnnamedTombstoneIsBackfilledOnLoad() {
        let (cwd, sid) = writeTranscript(lines: [
            #"{"type":"user","message":{"content":"Wire up the new monitor bar"}}"#
        ])
        let deadPid = 1_999_999
        let tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-title-mgr-\(UUID().uuidString)")
        let gavelDir = tmpHome.appendingPathComponent(".claude/gavel")
        try? FileManager.default.createDirectory(at: gavelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let state = #"{"live":[],"dead":[{"pid":\#(deadPid),"sessionId":"\#(sid)","cwd":"\#(cwd)"}]}"#
        try? state.write(to: gavelDir.appendingPathComponent("active-sessions.json"),
                         atomically: true, encoding: .utf8)

        let manager = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false)

        let tombstone = manager.deadSessions[sid]
        XCTAssertEqual(tombstone?.label, "Wire up the new monitor bar")
        XCTAssertEqual(tombstone?.labelIsDerived, true)
    }

    private func writeTranscript(lines: [String]) -> (cwd: String, sessionId: String) {
        let cwd = "/tmp/gavel-title-test-\(UUID().uuidString)"
        let sid = UUID().uuidString
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects")
            .appending("/\(encoded)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(sid).jsonl"
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        writtenPaths.append(path)
        return (cwd, sid)
    }
}
