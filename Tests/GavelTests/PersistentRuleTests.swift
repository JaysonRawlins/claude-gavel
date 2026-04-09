import XCTest
@testable import Gavel

final class PersistentRuleTests: XCTestCase {

    // MARK: - Glob patterns

    func testGlobMatchesWildcard() {
        var rule = PersistentRule(toolName: "Bash", pattern: "swift build*", verdict: .allow)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "swift build -c release", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "swift test", filePath: nil))
    }

    func testGlobWildcardMatchesAll() {
        var rule = PersistentRule(toolName: "Read", pattern: "*", verdict: .allow)
        XCTAssertTrue(rule.matches(toolName: "Read", command: nil, filePath: "/any/path"))
    }

    func testGlobWrongToolNoMatch() {
        var rule = PersistentRule(toolName: "Bash", pattern: "ls*", verdict: .allow)
        XCTAssertFalse(rule.matches(toolName: "Edit", command: "ls -la", filePath: nil))
    }

    // MARK: - Regex patterns

    func testRegexNegativeLookahead() {
        var rule = PersistentRule(toolName: "Bash", pattern: "doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, verdict: .block)
        // Without --only-names → matches (blocked)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "doppler secrets -p test -c dev", filePath: nil))
        // With --only-names → no match (allowed through)
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "doppler secrets --only-names -p test", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "doppler secrets -p test --only-names", filePath: nil))
    }

    func testRegexPositiveMatch() {
        var rule = PersistentRule(toolName: "Bash", pattern: "doppler\\s+secrets\\b.*--only-names", isRegex: true, verdict: .allow)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "doppler secrets --only-names", filePath: nil))
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "doppler secrets -p test -c dev --only-names", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "doppler secrets -p test", filePath: nil))
    }

    func testRegexDopplerRunEnvBlocked() {
        var rule = PersistentRule(toolName: "Bash", pattern: "doppler\\s+run\\b.*--\\s+(env|printenv|set)\\b", isRegex: true, verdict: .block)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "doppler run -p test -c dev -- env 2>&1", filePath: nil))
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "doppler run -- printenv", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "doppler run -- python app.py", filePath: nil))
    }

    // MARK: - Backward compatibility

    func testDecodesOldRulesWithoutIsRegex() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Bash: git*",
            "toolName": "Bash",
            "pattern": "git*",
            "verdict": "allow",
            "createdAt": 797440000.0
        }
        """
        let rule = try JSONDecoder().decode(PersistentRule.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(rule.isRegex, false)
        XCTAssertEqual(rule.pattern, "git*")
    }

    // MARK: - Em-dash sanitization in match targets

    func testEmDashSanitizedInTarget() {
        var rule = PersistentRule(toolName: "Bash", pattern: "doppler\\s+secrets\\b.*--only-names", isRegex: true, verdict: .allow)
        // Em-dash in command should be sanitized to ASCII before matching
        let cmdWithEmDash = "doppler secrets \u{2014}only-names"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: cmdWithEmDash, filePath: nil))
    }

    // MARK: - Priority chain (deny wins over allow)

    func testDenyWinsOverAllow() {
        let store = RuleStore(configPath: "/dev/null")
        // Add allow rule
        store.addRule(PersistentRule(toolName: "Bash", pattern: "doppler*", verdict: .allow))
        // Add deny rule
        store.addRule(PersistentRule(toolName: "Bash", pattern: "doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, verdict: .block))

        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("doppler secrets")])

        // Deny should fire first
        let deny = store.evaluateDeny(payload: payload)
        XCTAssertNotNil(deny)
        XCTAssertEqual(deny?.verdict, .block)
    }

    // MARK: - Engine integration: persistent allow skips dialog

    func testEngineReturnsAllowWithReasonForPersistentRule() {
        let store = RuleStore(configPath: "/dev/null")
        store.addRule(PersistentRule(toolName: "Bash", pattern: "git *", verdict: .allow))

        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 99999)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("git status")])

        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertNotNil(decision.reason) // non-nil reason = skip dialog in HookRouter
    }
}
