import XCTest
@testable import Gavel

/// PersistentRule (deny/prompt rules) must normalize shell line-continuations
/// the same way PatternMatcher does — otherwise a `\<newline>` splits a flag
/// from its command and slips past a single-line anchored deny rule.
final class PersistentRuleLineContinuationTests: XCTestCase {

    private func denyRule(_ pattern: String) -> PersistentRule {
        PersistentRule(toolName: "Bash", pattern: pattern, isRegex: true, verdict: .block)
    }

    func testRegexDenyControlMatches() {
        var rule = denyRule("git\\s+push\\b.*--force")
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "git push origin main --force", filePath: nil))
    }

    func testRegexDenyNotEvadedByContinuation() {
        var rule = denyRule("git\\s+push\\b.*--force")
        let split = "git push origin main \\\n  --force"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: split, filePath: nil),
                      "Line-continuation must not split push from --force")
    }

    func testRegexDenyNotEvadedByCRLFContinuation() {
        var rule = denyRule("git\\s+push\\b.*--force")
        let split = "git push origin main \\\r\n  --force"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: split, filePath: nil))
    }

    func testDopplerLookaheadAcrossContinuation() {
        var rule = denyRule("doppler\\s+secrets\\b(?!.*--only-names)")
        let split = "doppler secrets \\\n  download --no-file"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: split, filePath: nil),
                      "Continuation between secrets and download must still block")
    }

    func testPromptRuleNotEvadedByContinuation() {
        var rule = PersistentRule(toolName: "Bash", pattern: "rm\\s+-rf\\b.*/", isRegex: true, verdict: .prompt)
        let split = "rm -rf \\\n  /important/path"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: split, filePath: nil))
    }

    func testContinuationComposesWithSegmentSplitting() {
        // The dangerous segment is itself line-split AND followed by a safe
        // segment whose token would otherwise suppress the lookahead.
        var rule = denyRule("doppler\\s+secrets\\b(?!.*--only-names)")
        let cmd = "doppler secrets \\\n  download --no-file && doppler secrets --only-names"
        XCTAssertTrue(rule.matches(toolName: "Bash", command: cmd, filePath: nil))
    }

    func testNoFalsePositiveOnGenuineMultiline() {
        // No backslash — push and --force are in separate commands; must not block.
        var rule = denyRule("git\\s+push\\b.*--force")
        let multiline = "git push origin main\necho done\nmytool --force"
        XCTAssertFalse(rule.matches(toolName: "Bash", command: multiline, filePath: nil),
                       "Genuine command boundaries must not be bridged")
    }
}
