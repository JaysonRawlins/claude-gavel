import XCTest

@testable import Gavel

final class ProposalStoreTests: XCTestCase {
    private var dir: String!
    private var store: ProposalStore!
    private var ruleStore: RuleStore!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "proposals-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ruleStore = RuleStore(configPath: dir + "/rules.json")
        store = ProposalStore(path: dir + "/proposals.json")
        store.ruleStore = ruleStore
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func submit(
        tool: String = "Bash", pattern: String = "\\blaunchctl\\b\\s+bootstrap",
        isRegex: Bool = true, verdict: String = "prompt",
        reason: String = "launchctl bootstrap plants persistent execution",
        example: String? = "launchctl bootstrap gui/501 evil.plist", pid: Int = 4242
    ) -> ProposalStore.SubmitResult {
        store.submit(
            toolName: tool, pattern: pattern, isRegex: isRegex, verdict: verdict,
            reason: reason, example: example, sessionPid: pid, sessionId: nil)
    }

    // MARK: - Direction enforcement (the security property)

    func testAllowVerdictRejectedServerSide() {
        let result = submit(verdict: "allow")
        guard case .rejected(let reason) = result else {
            return XCTFail("allow proposals must never queue")
        }
        XCTAssertTrue(reason.contains("tighten-only"))
        XCTAssertTrue(store.proposals.isEmpty)
    }

    func testUnknownVerdictRejected() {
        guard case .rejected = submit(verdict: "yolo") else {
            return XCTFail("unknown verdict must be rejected")
        }
    }

    func testDenyAndPromptBothQueue() {
        guard case .queued = submit(verdict: "deny") else { return XCTFail("deny should queue") }
        guard case .queued = submit(pattern: "other", verdict: "prompt") else { return XCTFail("prompt should queue") }
        XCTAssertEqual(store.proposals.map(\.verdict), [.block, .prompt])
    }

    // MARK: - Validation

    func testBadRegexRejected() {
        guard case .rejected(let reason) = submit(pattern: "([unclosed") else {
            return XCTFail("non-compiling regex must be rejected")
        }
        XCTAssertTrue(reason.contains("compile"))
    }

    func testEmptyReasonRejected() {
        guard case .rejected = submit(reason: "") else {
            return XCTFail("reason is required")
        }
    }

    func testDuplicateOfExistingRuleRejected() {
        ruleStore.addRule(PersistentRule(toolName: "Bash", pattern: "already-covered", isRegex: true, verdict: .prompt))
        guard case .rejected(let reason) = submit(pattern: "already-covered") else {
            return XCTFail("duplicate of an existing rule must be rejected")
        }
        XCTAssertTrue(reason.contains("Duplicate"))
    }

    func testDuplicatePendingRejected() {
        guard case .queued = submit() else { return XCTFail() }
        guard case .rejected(let reason) = submit() else {
            return XCTFail("second identical proposal must be rejected")
        }
        XCTAssertTrue(reason.contains("Already proposed"))
    }

    func testPerSessionPendingCap() {
        for i in 0..<ProposalStore.maxPendingPerSession {
            guard case .queued = submit(pattern: "pattern-\(i)") else {
                return XCTFail("proposal \(i) should queue")
            }
        }
        guard case .rejected(let reason) = submit(pattern: "one-too-many") else {
            return XCTFail("cap must reject")
        }
        XCTAssertTrue(reason.contains("Too many"))

        // A different session is not capped by this one's backlog.
        guard case .queued = submit(pattern: "other-session", pid: 9999) else {
            return XCTFail("cap is per-session")
        }
    }

    // MARK: - Adjudication

    func testAcceptCreatesAuditedRuleAndDropsProposal() throws {
        guard case .queued(let id) = submit(verdict: "deny") else { return XCTFail() }

        let rule = try XCTUnwrap(store.accept(id: id, via: "monitor"))
        XCTAssertEqual(rule.verdict, .block)
        XCTAssertEqual(rule.pattern, "\\blaunchctl\\b\\s+bootstrap")
        XCTAssertEqual(rule.explanation, "launchctl bootstrap plants persistent execution")
        XCTAssertTrue(store.proposals.isEmpty)
        XCTAssertTrue(ruleStore.rules.contains { $0.id == rule.id })

        let audit = try XCTUnwrap(ruleStore.auditLog)
        let entry = try XCTUnwrap(audit.entries().last)
        XCTAssertEqual(entry.action, "rule_added")
        XCTAssertTrue(entry.origin.contains("claude-proposal pid=4242"))
        XCTAssertTrue(entry.origin.contains("accepted-via=monitor"))
        XCTAssertNil(audit.verifyChain())
    }

    func testRejectDropsProposalAndAudits() throws {
        guard case .queued(let id) = submit() else { return XCTFail() }

        store.reject(id: id, via: "monitor")
        XCTAssertTrue(store.proposals.isEmpty)
        XCTAssertFalse(ruleStore.rules.contains { $0.pattern == "\\blaunchctl\\b\\s+bootstrap" })

        let entry = try XCTUnwrap(ruleStore.auditLog?.entries().last)
        XCTAssertEqual(entry.action, "proposal_rejected")
        XCTAssertTrue(entry.origin.contains("rejected-via=monitor"))
    }

    func testAcceptUnknownIdIsNoOp() {
        XCTAssertNil(store.accept(id: UUID()))
        XCTAssertTrue(ruleStore.rules.filter { !$0.builtIn }.isEmpty)
    }

    // MARK: - Persistence

    func testProposalsSurviveRestart() throws {
        guard case .queued(let id) = submit() else { return XCTFail() }

        let reloaded = ProposalStore(path: dir + "/proposals.json")
        XCTAssertEqual(reloaded.proposals.map(\.id), [id])
        XCTAssertEqual(reloaded.proposals.first?.reason, "launchctl bootstrap plants persistent execution")
    }

    func testOnChangeFiresOnMainWithSnapshot() {
        let expectation = expectation(description: "onChange")
        var received: [RuleProposal]?
        store.onChange = { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            received = snapshot
            expectation.fulfill()
        }
        guard case .queued = submit() else { return XCTFail() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received?.count, 1)
    }
}
