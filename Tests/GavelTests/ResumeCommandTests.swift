import XCTest
@testable import Gavel

final class ResumeCommandTests: XCTestCase {

    // MARK: - shellQuote

    func testQuotesSimplePath() {
        XCTAssertEqual(ResumeCommand.shellQuote("/Users/jay/code"), "'/Users/jay/code'")
    }

    func testQuotesPathWithSpaces() {
        XCTAssertEqual(
            ResumeCommand.shellQuote("/Users/jay/My Projects/repo"),
            "'/Users/jay/My Projects/repo'"
        )
    }

    func testEscapesEmbeddedApostrophe() {
        // bash form: 'foo'\''bar' represents the string foo'bar
        XCTAssertEqual(
            ResumeCommand.shellQuote("/Users/jay/foo'bar"),
            "'/Users/jay/foo'\\''bar'"
        )
    }

    func testEscapesMultipleApostrophes() {
        XCTAssertEqual(
            ResumeCommand.shellQuote("a'b'c"),
            "'a'\\''b'\\''c'"
        )
    }

    func testQuotesEmptyString() {
        XCTAssertEqual(ResumeCommand.shellQuote(""), "''")
    }

    func testQuotesPathWithDollarAndBackticksLiterally() {
        // Single quotes neutralize $ and ` in bash, so no escape needed.
        XCTAssertEqual(
            ResumeCommand.shellQuote("/tmp/$HOME/`whoami`"),
            "'/tmp/$HOME/`whoami`'"
        )
    }

    // MARK: - build

    func testBuildWithCwd() {
        let cmd = ResumeCommand.build(
            pid: 12345,
            sessionId: "abc-def-123",
            cwd: "/Users/jay/project"
        )
        XCTAssertEqual(cmd, "cd '/Users/jay/project' && claude --name 12345 --resume abc-def-123")
    }

    func testBuildWithoutCwdOmitsCdPrefix() {
        let cmd = ResumeCommand.build(pid: 42, sessionId: "sid-9", cwd: nil)
        XCTAssertEqual(cmd, "claude --name 42 --resume sid-9")
    }

    func testBuildEscapesCwdSpaces() {
        let cmd = ResumeCommand.build(
            pid: 1,
            sessionId: "s",
            cwd: "/Users/jay/My Projects"
        )
        XCTAssertEqual(cmd, "cd '/Users/jay/My Projects' && claude --name 1 --resume s")
    }

    func testBuildCodexAgentEmitsCodexResume() {
        let cmd = ResumeCommand.build(
            pid: 9999,
            sessionId: "019e38ed-2ed8-7cd2-ae18-e5f6eaec080b",
            cwd: "/tmp/codex-spike-sandbox",
            agent: .codex
        )
        XCTAssertEqual(cmd, "cd '/tmp/codex-spike-sandbox' && codex resume 019e38ed-2ed8-7cd2-ae18-e5f6eaec080b")
    }

    func testBuildCodexWithoutCwdOmitsCdPrefix() {
        let cmd = ResumeCommand.build(pid: 7, sessionId: "abc", cwd: nil, agent: .codex)
        XCTAssertEqual(cmd, "codex resume abc")
    }
}
