import XCTest
@testable import Gavel

final class SessionTagTests: XCTestCase {

    // MARK: - Store: dedup + keep-first

    func testAddObservedDedupesByNameKeepingFirstTimestamp() {
        let store = SessionTagStore()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)

        XCTAssertTrue(store.addObserved("skill:daybook", at: t1))
        XCTAssertFalse(store.addObserved("skill:daybook", at: t2))

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.snapshot.first?.appliedAt, t1)
        XCTAssertEqual(store.snapshot.first?.source, .observed)
    }

    func testSnapshotOrdersByAppliedAtThenName() {
        let store = SessionTagStore()
        store.addObserved("skill:b", at: Date(timeIntervalSince1970: 2000))
        store.addObserved("skill:a", at: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(store.snapshot.map(\.name), ["skill:a", "skill:b"])
    }

    // MARK: - Store: filter predicate

    func testMatchesTokenIsCaseInsensitiveSubstring() {
        let store = SessionTagStore()
        store.addObserved("skill:daybook", at: Date())

        XCTAssertTrue(store.matches(token: "daybook"))
        XCTAssertTrue(store.matches(token: "skill:daybook"))
        XCTAssertTrue(store.matches(token: "SKILL:DAYBOOK"))
        XCTAssertFalse(store.matches(token: "jira"))
    }

    // MARK: - Store: load (persistence restore)

    func testLoadRestoresTagsAndStaysIdempotent() {
        let store = SessionTagStore()
        let original = SessionTag(name: "skill:jira", appliedAt: Date(timeIntervalSince1970: 500), source: .observed)
        store.load([original])
        store.load([SessionTag(name: "skill:jira", appliedAt: Date(timeIntervalSince1970: 999), source: .observed)])

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.snapshot.first?.appliedAt, original.appliedAt)
    }

    // MARK: - Codable round-trip

    func testSessionTagCodableRoundTrip() throws {
        let tags = [
            SessionTag(name: "skill:daybook", appliedAt: Date(timeIntervalSince1970: 1000), source: .observed),
            SessionTag(name: "manual:hot", appliedAt: Date(timeIntervalSince1970: 2000), source: .manual)
        ]
        let data = try JSONEncoder().encode(tags)
        let decoded = try JSONDecoder().decode([SessionTag].self, from: data)
        XCTAssertEqual(decoded, tags)
    }

    // MARK: - Payload accessor

    func testPayloadExtractsSkillName() {
        let payload = PreToolUsePayload(toolName: "Skill", toolInput: ["skill": AnyCodable("daybook")])
        XCTAssertEqual(payload.skill, "daybook")
    }

    func testPayloadSkillNilWhenAbsent() {
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("ls")])
        XCTAssertNil(payload.skill)
    }

    // MARK: - HookRouter observation integration

    private func makeIsolatedManager() -> SessionManager {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-tag-tests-\(UUID().uuidString)")
        return SessionManager(homeDir: tmp, autoStartTimers: false, autoDiscover: false)
    }

    private func makeRouter(_ manager: SessionManager) -> HookRouter {
        let engine = ApprovalEngine(ruleStore: RuleStore(configPath: "/dev/null"))
        return HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: ApprovalCoordinator())
    }

    private func skillEvent(pid: Int, skill: String, ts: Double) -> Data {
        """
        {
            "hookType": "PreToolUse",
            "sessionPid": \(pid),
            "timestamp": \(ts),
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Skill",
                "tool_input": {"skill": "\(skill)"},
                "session_id": "tag-test"
            }
        }
        """.data(using: .utf8)!
    }

    func testRouterTagsSessionOnSkillCall() {
        let manager = makeIsolatedManager()
        let session = manager.session(for: 71001)
        session.isAutoApproveEnabled = true
        let router = makeRouter(manager)

        router.handle(data: skillEvent(pid: 71001, skill: "daybook", ts: 1712600000.0), respond: { _ in })

        XCTAssertTrue(session.tags.matches(token: "skill:daybook"))
        XCTAssertEqual(session.tags.count, 1)
    }

    func testRouterDoesNotDoubleTagRepeatedSkill() {
        let manager = makeIsolatedManager()
        let session = manager.session(for: 71002)
        session.isAutoApproveEnabled = true
        let router = makeRouter(manager)

        router.handle(data: skillEvent(pid: 71002, skill: "daybook", ts: 1712600000.0), respond: { _ in })
        router.handle(data: skillEvent(pid: 71002, skill: "daybook", ts: 1712600099.0), respond: { _ in })

        XCTAssertEqual(session.tags.count, 1)
        XCTAssertEqual(session.tags.snapshot.first?.appliedAt, Date(timeIntervalSince1970: 1712600000.0))
    }

    func testRouterDoesNotTagOnNonSkillCall() {
        let manager = makeIsolatedManager()
        let session = manager.session(for: 71003)
        session.isAutoApproveEnabled = true
        let router = makeRouter(manager)

        let bash = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 71003,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "session_id": "tag-test"
            }
        }
        """.data(using: .utf8)!
        router.handle(data: bash, respond: { _ in })

        XCTAssertTrue(session.tags.isEmpty)
    }
}
