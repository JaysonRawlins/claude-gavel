import XCTest

@testable import Gavel

/// Wire-level coverage for the ProposeRule channel: a raw gavel-hook envelope
/// through HookRouter to the ProposalStore and back out as a JSON ack.
final class ProposeRuleWireTests: XCTestCase {
    private var dir: String!
    private var ruleStore: RuleStore!
    private var proposalStore: ProposalStore!
    private var router: HookRouter!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "propose-wire-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ruleStore = RuleStore(configPath: dir + "/rules.json")
        proposalStore = ProposalStore(path: dir + "/proposals.json")
        proposalStore.ruleStore = ruleStore

        let engine = ApprovalEngine(patternMatcher: PatternMatcher(), ruleStore: ruleStore)
        router = HookRouter(
            sessionManager: SessionManager(),
            approvalEngine: engine,
            approvalCoordinator: ApprovalCoordinator()
        )
        router.proposalStore = proposalStore
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func send(verdict: String, pattern: String = "\\\\blaunchctl\\\\b", reason: String = "plants persistent execution outside the session") -> [String: Any]? {
        let json = """
        {
            "hookType": "ProposeRule",
            "sessionPid": 77001,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "ProposeRule",
                "tool_name": "Bash",
                "pattern": "\(pattern)",
                "is_regex": true,
                "verdict": "\(verdict)",
                "reason": "\(reason)",
                "example": "launchctl bootstrap gui/501 evil.plist",
                "session_id": "wire-test"
            }
        }
        """
        var response: [String: Any]?
        router.handle(data: json.data(using: .utf8)!) { data in
            response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return response
    }

    func testProposalQueuesOverTheWire() {
        let response = send(verdict: "prompt")
        XCTAssertEqual(response?["status"] as? String, "queued")
        XCTAssertNotNil(response?["id"] as? String)

        XCTAssertEqual(proposalStore.proposals.count, 1)
        XCTAssertEqual(proposalStore.proposals.first?.verdict, .prompt)
        XCTAssertEqual(proposalStore.proposals.first?.sessionPid, 77001)
        XCTAssertEqual(proposalStore.proposals.first?.example, "launchctl bootstrap gui/501 evil.plist")
        // Inert until accepted: no rule was created.
        XCTAssertFalse(ruleStore.rules.contains { $0.pattern.contains("launchctl") })
    }

    func testAllowVerdictRejectedOverTheWire() {
        let response = send(verdict: "allow")
        XCTAssertEqual(response?["status"] as? String, "rejected")
        XCTAssertTrue((response?["reason"] as? String ?? "").contains("tighten-only"))
        XCTAssertTrue(proposalStore.proposals.isEmpty)
    }

    func testMissingProposalStoreFailsClosed() {
        router.proposalStore = nil
        let response = send(verdict: "deny")
        XCTAssertEqual(response?["status"] as? String, "rejected")
    }

    func testProposeRuleEnvelopeDecodes() throws {
        let json = """
        {
            "hookType": "ProposeRule",
            "sessionPid": 1,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "ProposeRule",
                "tool_name": "*",
                "pattern": "^CronCreate$",
                "is_regex": true,
                "verdict": "deny",
                "reason": "scheduler tools plant delayed execution"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.hookType, .proposeRule)
        guard case .proposeRule(let payload) = event.payload else {
            return XCTFail("expected proposeRule payload, got \(event.payload)")
        }
        XCTAssertEqual(payload.toolName, "*")
        XCTAssertEqual(payload.pattern, "^CronCreate$")
        XCTAssertEqual(payload.isRegex, true)
        XCTAssertEqual(payload.verdict, "deny")
    }
}
