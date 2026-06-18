import XCTest
@testable import Gavel

final class SkillTagHandlerTests: XCTestCase {

    private func isolatedManager() -> SessionManager {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-skilltag-tests-\(UUID().uuidString)")
        return SessionManager(homeDir: tmp, autoStartTimers: false, autoDiscover: false)
    }

    private func event(_ line: String, ts: String? = nil, type: String = "user") -> JsonlEvent {
        var json: [String: Any] = ["type": type]
        if let ts = ts { json["timestamp"] = ts }
        return JsonlEvent(rawLine: line, json: json, sessionId: "s", cwd: "/tmp")
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    func testTagsKnownSkillFromCommandName() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81001)
        handler.handle(event(#"{"x":"<command-name>/daybook</command-name>"}"#), manager: manager, session: session)
        XCTAssertTrue(session.tags.matches(token: "skill:daybook"))
        XCTAssertEqual(session.tags.count, 1)
    }

    func testNoLeadingSlashAlsoTags() {
        let handler = SkillTagHandler(knownSkills: ["lookup"])
        let manager = isolatedManager()
        let session = manager.session(for: 81002)
        handler.handle(event("<command-name>lookup</command-name>"), manager: manager, session: session)
        XCTAssertTrue(session.tags.matches(token: "skill:lookup"))
    }

    func testIgnoresCommandThatIsNotAKnownSkill() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81003)
        handler.handle(event("<command-name>/rename</command-name>"), manager: manager, session: session)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testNoCommandNameRecordsNothing() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81004)
        handler.handle(event(#"{"type":"user","message":"just some text"}"#), manager: manager, session: session)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testDedupesRepeatedInvocation() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81005)
        let line = "<command-name>/daybook</command-name>"
        handler.handle(event(line, ts: "2026-06-18T18:00:00.000Z"), manager: manager, session: session)
        handler.handle(event(line, ts: "2026-06-18T19:00:00.000Z"), manager: manager, session: session)
        XCTAssertEqual(session.tags.count, 1)
        XCTAssertEqual(session.tags.snapshot.first?.appliedAt, date("2026-06-18T18:00:00.000Z"))
    }

    func testManualMarkerTagsKnownSkill() {
        let handler = SkillTagHandler(knownSkills: ["jira"])
        let manager = isolatedManager()
        let session = manager.session(for: 81010)
        handler.handle(event("please add the tag [[/jira]] retroactively"), manager: manager, session: session)
        XCTAssertTrue(session.tags.matches(token: "skill:jira"))
        XCTAssertEqual(session.tags.snapshot.first?.source, .manual)
    }

    func testManualMarkerIgnoresUnknownSkill() {
        let handler = SkillTagHandler(knownSkills: ["jira"])
        let manager = isolatedManager()
        let session = manager.session(for: 81011)
        handler.handle(event("[[/not-a-skill]]"), manager: manager, session: session)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testManualMarkerDoesNotOverrideObservedSource() {
        let handler = SkillTagHandler(knownSkills: ["jira"])
        let manager = isolatedManager()
        let session = manager.session(for: 81012)
        handler.handle(event("<command-name>/jira</command-name>"), manager: manager, session: session)
        handler.handle(event("[[/jira]]"), manager: manager, session: session)
        XCTAssertEqual(session.tags.count, 1)
        XCTAssertEqual(session.tags.snapshot.first?.source, .observed)
    }

    func testIgnoresNonUserEntry() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81013)
        handler.handle(event("<command-name>/daybook</command-name> and [[/daybook]]", type: "assistant"),
                       manager: manager, session: session)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testEmptyKnownSkillsIsNoOp() {
        let handler = SkillTagHandler(knownSkills: [])
        let manager = isolatedManager()
        let session = manager.session(for: 81006)
        handler.handle(event("<command-name>/daybook</command-name>"), manager: manager, session: session)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testTimestampParsedFromEventJson() {
        let handler = SkillTagHandler(knownSkills: ["daybook"])
        let manager = isolatedManager()
        let session = manager.session(for: 81007)
        handler.handle(event("<command-name>/daybook</command-name>", ts: "2026-06-18T18:00:00.000Z"),
                       manager: manager, session: session)
        XCTAssertEqual(session.tags.snapshot.first?.appliedAt, date("2026-06-18T18:00:00.000Z"))
    }

    func testDiscoverSkillsReadsSubdirectories() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-skills-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("daybook"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("lookup"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("loose-file.md").path, contents: Data())

        let discovered = SkillTagHandler.discoverSkills(in: dir.path)
        XCTAssertEqual(discovered, ["daybook", "lookup"])
    }
}
