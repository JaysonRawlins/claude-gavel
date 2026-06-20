import XCTest
@testable import Gavel

/// Covers the manual "Name Unnamed" action that re-derives names for still-blank sessions the one-shot seed guard skipped.
final class NameUnnamedSessionsTests: XCTestCase {

    private var tmpHome: URL!
    private var manager: SessionManager!
    private var writtenPaths: [String] = []
    private let deadPid = 1_999_998

    private let liveOnOwnPid: (Int, String?) -> Bool = { pid, cwd in
        pid == Int(getpid()) ? true : SessionManager.defaultLiveness(pid: pid, cwd: cwd)
    }

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-nameunnamed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        manager = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false, liveness: liveOnOwnPid)
    }

    override func tearDown() {
        for path in writtenPaths { try? FileManager.default.removeItem(atPath: path) }
        writtenPaths.removeAll()
        manager = nil
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    func testNamesBlankLiveSessionFromTranscript() {
        let cwd = "/tmp/gavel-nameunnamed-live-\(UUID().uuidString)"
        let sid = UUID().uuidString
        writeTranscript(cwd: cwd, sid: sid, lines: [
            #"{"type":"user","message":{"content":"give me the history of why americans drink coffee and english tend to drink tea"}}"#
        ])
        let session = manager.session(for: Int(getpid()))
        session.sessionId = sid
        session.cwd = cwd

        let named = manager.nameUnnamedSessions()

        XCTAssertEqual(named, 1)
        XCTAssertTrue(session.label.hasPrefix("give me the history of why americans drink coffee"))
        XCTAssertTrue(session.labelIsDerived)
    }

    func testNamesBlankTombstoneWhenTranscriptAppearsAfterSeed() {
        let cwd = "/tmp/gavel-nameunnamed-tomb-\(UUID().uuidString)"
        let sid = UUID().uuidString
        let session = manager.session(for: deadPid)
        session.sessionId = sid
        session.cwd = cwd
        manager.cleanupDeadSessions()
        XCTAssertEqual(manager.deadSessions[sid]?.label, "")

        writeTranscript(cwd: cwd, sid: sid, lines: [
            #"{"type":"user","message":{"content":"Wire up the new monitor bar"}}"#
        ])

        let named = manager.nameUnnamedSessions()

        XCTAssertEqual(named, 1)
        XCTAssertEqual(manager.deadSessions[sid]?.label, "Wire up the new monitor bar")
        XCTAssertEqual(manager.deadSessions[sid]?.labelIsDerived, true)
    }

    func testLeavesSessionBlankWhenNoTranscript() {
        let session = manager.session(for: Int(getpid()))
        session.sessionId = UUID().uuidString
        session.cwd = "/tmp/gavel-nameunnamed-missing-\(UUID().uuidString)"

        let named = manager.nameUnnamedSessions()

        XCTAssertEqual(named, 0)
        XCTAssertTrue(session.label.isEmpty)
    }

    @discardableResult
    private func writeTranscript(cwd: String, sid: String, lines: [String]) -> String {
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
        return path
    }
}
