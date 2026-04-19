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

    // MARK: - Wildcard rules match MCP tool names

    func testWildcardRuleMatchesMcpToolName() {
        var rule = PersistentRule(toolName: "*", pattern: "mcp__LinkedIn__(linkedin_create|linkedin_post)", isRegex: true, verdict: .prompt)
        // MCP tools have no command/filePath — pattern should match against the tool name
        XCTAssertTrue(rule.matches(toolName: "mcp__LinkedIn__linkedin_create_post", command: nil, filePath: nil))
    }

    func testWildcardRuleNoFalsePositiveOnToolName() {
        var rule = PersistentRule(toolName: "*", pattern: "mcp__LinkedIn__linkedin_create", isRegex: true, verdict: .prompt)
        // Should not match a different tool
        XCTAssertFalse(rule.matches(toolName: "mcp__engram__search", command: nil, filePath: nil))
    }

    func testWildcardPromptRuleForcesDialogInEngine() {
        let store = RuleStore(configPath: "/dev/null")
        store.addRule(PersistentRule(toolName: "*", pattern: "mcp__LinkedIn__(linkedin_create|linkedin_post)", isRegex: true, verdict: .prompt))

        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 99999)
        let payload = PreToolUsePayload(toolName: "mcp__LinkedIn__linkedin_create_post", toolInput: [:])

        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser) // askUser = forceDialog in HookRouter
    }

    func testNonWildcardRuleDoesNotMatchToolName() {
        // When toolName is specific (not *), it should NOT fall back to tool name matching
        var rule = PersistentRule(toolName: "Bash", pattern: "mcp__LinkedIn__linkedin_create", isRegex: true, verdict: .prompt)
        XCTAssertFalse(rule.matches(toolName: "mcp__LinkedIn__linkedin_create_post", command: nil, filePath: nil))
    }

    // MARK: - Built-in flag

    func testBuiltInDefaultsFalse() {
        let rule = PersistentRule(toolName: "Bash", pattern: "git *", verdict: .allow)
        XCTAssertFalse(rule.builtIn)
    }

    func testBuiltInFlagBackwardCompat() throws {
        // Old rules.json without builtIn field should decode as false
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Bash: git*",
            "toolName": "Bash",
            "pattern": "git*",
            "verdict": "allow",
            "createdAt": 797440000.0
        }
        """
        let rule = try JSONDecoder().decode(PersistentRule.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(rule.builtIn)
    }

    func testBuiltInFlagDecodesWhenPresent() throws {
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "*: /mcp__.*slack.*/",
            "toolName": "*",
            "pattern": "mcp__.*slack.*send",
            "isRegex": true,
            "verdict": "prompt",
            "createdAt": 797440000.0,
            "builtIn": true
        }
        """
        let rule = try JSONDecoder().decode(PersistentRule.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(rule.builtIn)
        XCTAssertTrue(rule.isRegex)
    }

    // MARK: - Seeding

    func testSeededDefaultsArePresent() {
        let store = RuleStore(configPath: "/dev/null")
        let builtInRules = store.rules.filter { $0.builtIn }
        XCTAssertEqual(builtInRules.count, RuleStore.seededDefaults.count)
        // v6: 5 MCP exfil + 1 self-protection + 1 scripting + 3 sandbox escape + 2 git safety = 12
        XCTAssertEqual(builtInRules.count, 12)
    }

    func testSeededRulesArePromptVerdict() {
        let store = RuleStore(configPath: "/dev/null")
        let builtInRules = store.rules.filter { $0.builtIn }
        for rule in builtInRules {
            XCTAssertEqual(rule.verdict, .prompt)
        }
    }

    // MARK: - Scripting execution built-in

    func testScriptingPromptMatchesPython() {
        let store = RuleStore(configPath: "/dev/null")
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: [
            "command": AnyCodable("python3 -c \"import subprocess; subprocess.run(['ls'])\"")
        ])
        let decision = store.evaluateBuiltInPrompt(payload: payload)
        XCTAssertNotNil(decision, "Built-in scripting rule should match python3 -c")
        XCTAssertTrue(decision?.askUser ?? false)
    }

    func testScriptingPromptMatchesRuby() {
        let store = RuleStore(configPath: "/dev/null")
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: [
            "command": AnyCodable("ruby -e \"system('ls')\"")
        ])
        XCTAssertNotNil(store.evaluateBuiltInPrompt(payload: payload))
    }

    func testScriptingPromptDoesNotMatchPythonScript() {
        // Running a .py file is not inline execution
        let store = RuleStore(configPath: "/dev/null")
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: [
            "command": AnyCodable("python3 test_script.py")
        ])
        XCTAssertNil(store.evaluateBuiltInPrompt(payload: payload))
    }

    // MARK: - Split prompt evaluation

    func testEvaluateUserPromptSkipsBuiltIn() {
        let store = RuleStore(configPath: "/dev/null")
        // All seeded rules are builtIn — evaluateUserPrompt should skip them
        let payload = PreToolUsePayload(toolName: "mcp__SlackLocal__send_message", toolInput: [:])
        XCTAssertNil(store.evaluateUserPrompt(payload: payload))
    }

    func testEvaluateBuiltInPromptMatchesSeeded() {
        let store = RuleStore(configPath: "/dev/null")
        let payload = PreToolUsePayload(toolName: "mcp__SlackLocal__send_message", toolInput: [:])
        let decision = store.evaluateBuiltInPrompt(payload: payload)
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.verdict, .block)
        XCTAssertTrue(decision?.askUser ?? false)
    }

    func testEvaluateBuiltInPromptSkipsUserRules() {
        let store = RuleStore(configPath: "/dev/null")
        store.addRule(PersistentRule(toolName: "*", pattern: "mcp__custom__deploy", isRegex: true, verdict: .prompt))
        let payload = PreToolUsePayload(toolName: "mcp__custom__deploy", toolInput: [:])
        // evaluateBuiltInPrompt should NOT match user-created prompt rule
        XCTAssertNil(store.evaluateBuiltInPrompt(payload: payload))
        // evaluateUserPrompt SHOULD match it
        XCTAssertNotNil(store.evaluateUserPrompt(payload: payload))
    }

    // MARK: - Self-protection built-in rules

    func testCatOnGavelRulesPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("cat ~/.claude/gavel/rules.json")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testCatOnClaudeSettingsPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("cat ~/.claude/settings.json")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testEchoRedirectToRulesPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("echo '[]' > ~/.claude/gavel/rules.json")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testChmodOnGavelHooksPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("chmod 000 ~/.claude/gavel/hooks/pre_tool_use.sh")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testSedOnGavelConfigPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("sed -n '1,5p' ~/.claude/gavel/rules.json")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testJqOnGavelConfigPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("jq '.rules | length' ~/.claude/gavel/rules.json")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testSymlinkToGavelConfigPrompts() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("ln -s ~/.claude/gavel/rules.json /tmp/link")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testNormalBashNotCaughtBySelfProtection() {
        let store = RuleStore(configPath: "/dev/null")
        let engine = ApprovalEngine(ruleStore: store)
        let session = Session(pid: 88888)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("cat README.md")])
        let decision = engine.evaluate(payload: payload, session: session)
        XCTAssertEqual(decision.verdict, .allow)
    }
}
