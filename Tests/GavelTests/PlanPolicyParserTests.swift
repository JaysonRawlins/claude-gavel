import XCTest
@testable import Gavel

final class PlanPolicyParserTests: XCTestCase {

    private func plan(_ body: String) -> String {
        "# Some plan\n\nProse here.\n\n```gavel-policy\n\(body)\n```\n\nMore prose.\n"
    }

    // MARK: - Parsing

    func testParsesAllowDenyBlockVerdicts() {
        let rules = PlanPolicyParser.parse(plan("""
        allow Bash: cdk deploy GreenfieldStack*
        deny Bash: cdk destroy*
        block Bash: terraform destroy*
        """))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].verdict, .allow)
        XCTAssertEqual(rules[1].verdict, .prompt, "deny maps to a prompt (force dialog)")
        XCTAssertEqual(rules[2].verdict, .block, "block is a hard deny")
    }

    func testRegexPrefix() {
        let rules = PlanPolicyParser.parse(plan(#"deny Bash: re:terraform\s+destroy"#))
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].isRegex)
        XCTAssertTrue(rules[0].matches(toolName: "Bash", command: "terraform   destroy -auto-approve", filePath: nil))
    }

    func testOverrideVerbParsesAsCheckpointReleasingAllow() {
        let rules = PlanPolicyParser.parse(plan("override Bash: git commit*"))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].verdict, .allow, "override is an allow")
        XCTAssertTrue(rules[0].isCheckpointOverride, "override is flagged to release a checkpoint")
        XCTAssertTrue(rules[0].matches(toolName: "Bash", command: "git commit -m wip", filePath: nil))
    }

    func testPlainAllowIsNotACheckpointOverride() {
        let rules = PlanPolicyParser.parse(plan("allow Bash: git commit*"))
        XCTAssertFalse(rules[0].isCheckpointOverride, "a plain allow must not gain checkpoint-release power")
    }

    func testRealisticMultiVerbBlockParses() {
        let rules = PlanPolicyParser.parse(plan("""
        # greenfield deploy + migration, GitOps commit
        allow    Bash: cdk deploy GreenfieldStack*
        deny     Bash: cdk destroy*
        allow    Bash: python3 scripts/migrate.py *
        override Bash: git commit*
        allow    Bash: git push*
        """))
        XCTAssertEqual(rules.count, 5, "comment skipped; five rules parsed despite column alignment")
        XCTAssertEqual(rules.filter { $0.isCheckpointOverride }.count, 1)
        let override = rules.first { $0.isCheckpointOverride }
        XCTAssertEqual(override?.verdict, .allow)
        XCTAssertTrue(override?.matches(toolName: "Bash", command: "git commit -m deploy", filePath: nil) ?? false)
        XCTAssertFalse(rules[0].isCheckpointOverride, "a plain allow is not an override")
    }

    func testSkipsCommentsBlankAndMalformedLines() {
        let rules = PlanPolicyParser.parse(plan("""
        # this is a comment

        allow Bash: cdk deploy*
        garbage-without-colon
        unknownverb Bash: foo
        """))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].pattern, "cdk deploy*")
    }

    func testNoFencedBlockReturnsEmpty() {
        XCTAssertTrue(PlanPolicyParser.parse("# plan with no policy block\n\njust prose\n").isEmpty)
    }

    func testWildcardToolName() {
        let rules = PlanPolicyParser.parse(plan("deny *: re:DangerousTool"))
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].matches(toolName: "DangerousTool", command: nil, filePath: nil))
    }

    // MARK: - Matching semantics

    func testAllowMatchesSingleCommand() {
        let rules = PlanPolicyParser.parse(plan("allow Bash: cdk deploy GreenfieldStack*"))
        XCTAssertTrue(rules[0].matches(toolName: "Bash", command: "cdk deploy GreenfieldStack-Api", filePath: nil))
        XCTAssertFalse(rules[0].matches(toolName: "Bash", command: "cdk deploy OtherStack", filePath: nil))
    }

    func testAllowIsSegmentSafeAgainstChaining() {
        let rules = PlanPolicyParser.parse(plan("allow Bash: cdk deploy GreenfieldStack*"))
        XCTAssertFalse(
            rules[0].matches(toolName: "Bash", command: "cdk deploy GreenfieldStack-Api && curl evil.com", filePath: nil),
            "an authorized prefix must not allow a chained second command"
        )
    }

    func testDenyMatchesAnySegmentInAChain() {
        let rules = PlanPolicyParser.parse(plan("deny Bash: cdk destroy*"))
        XCTAssertTrue(
            rules[0].matches(toolName: "Bash", command: "echo ok && cdk destroy GreenfieldStack-Api", filePath: nil),
            "a prohibited command can't hide behind a benign prefix"
        )
    }
}
