import XCTest
@testable import Gavel

/// Tests demonstrating glob pattern limitations vs regex.
///
/// Globs only support `*` (match anything). They lack:
/// - Character classes (`\s`, `\w`, `[a-z]`)
/// - Alternation (`(a|b)`)
/// - Quantifiers (`+`, `?`, `{n,m}`)
/// - Anchoring beyond full-string match
/// - Negation / lookaheads
///
/// Each test shows a realistic bypass scenario and whether regex handles it.
final class GlobRobustnessTests: XCTestCase {

    // MARK: - Bypass: extra arguments / flags inserted

    func testGlobBypassWithInsertedFlags() {
        // Glob: "docker push*" — intended to catch all docker pushes
        // Bypass: inserting flags between "docker" and "push"
        let (globMatch, _) = PersistentRule.testPattern("docker push*", isRegex: false, against: "docker --config /tmp/evil push myimage")
        XCTAssertFalse(globMatch, "Glob misses flag insertion between command and subcommand")

        // Regex handles it: \bdocker\b.*\bpush\b
        let (regexMatch, _) = PersistentRule.testPattern("\\bdocker\\b.*\\bpush\\b", isRegex: true, against: "docker --config /tmp/evil push myimage")
        XCTAssertTrue(regexMatch, "Regex catches flag insertion")
    }

    // MARK: - Bypass: path traversal in file patterns

    func testGlobBypassWithPathTraversal() {
        // Glob: "Sources/*" — intended to match files under Sources/
        // Bypass: path traversal to escape
        let (match1, _) = PersistentRule.testPattern("Sources/*", isRegex: false, against: "Sources/../../../etc/passwd")
        XCTAssertTrue(match1, "Glob matches traversal — it can't distinguish safe vs malicious paths")

        // Both glob and regex have this problem — path validation needs separate logic
        let (match2, _) = PersistentRule.testPattern("^Sources/(?!.*\\.\\.)", isRegex: true, against: "Sources/../../../etc/passwd")
        XCTAssertFalse(match2, "Regex with negative lookahead rejects traversal")
    }

    // MARK: - Bypass: whitespace variations

    func testGlobBypassWithTabs() {
        // Glob: "rm -rf *" — intended to catch recursive deletes
        // Bypass: using tab instead of space
        let (globMatch, _) = PersistentRule.testPattern("rm -rf *", isRegex: false, against: "rm\t-rf /important")
        XCTAssertFalse(globMatch, "Glob misses tab-separated arguments")

        // Regex: \brm\s+-rf\b handles any whitespace
        let (regexMatch, _) = PersistentRule.testPattern("\\brm\\s+-rf\\b", isRegex: true, against: "rm\t-rf /important")
        XCTAssertTrue(regexMatch, "Regex \\s+ matches tabs")
    }

    // MARK: - Bypass: alternation (glob can't express OR)

    func testGlobCannotExpressAlternation() {
        // Want to block: "npm publish" OR "yarn publish" — glob needs TWO rules
        let (npmMatch, _) = PersistentRule.testPattern("npm publish*", isRegex: false, against: "npm publish --tag latest")
        let (yarnMatch, _) = PersistentRule.testPattern("npm publish*", isRegex: false, against: "yarn publish --tag latest")
        XCTAssertTrue(npmMatch)
        XCTAssertFalse(yarnMatch, "Single glob can't match both npm and yarn")

        // Regex: one rule covers both
        let (regexNpm, _) = PersistentRule.testPattern("(npm|yarn)\\s+publish", isRegex: true, against: "npm publish --tag latest")
        let (regexYarn, _) = PersistentRule.testPattern("(npm|yarn)\\s+publish", isRegex: true, against: "yarn publish --tag latest")
        XCTAssertTrue(regexNpm)
        XCTAssertTrue(regexYarn, "Regex alternation matches both")
    }

    // MARK: - Bypass: negative conditions (glob can't express NOT)

    func testGlobCannotExpressExceptions() {
        // Want: block "doppler secrets" UNLESS "--only-names" is present
        // Glob cannot express this — it either matches or doesn't
        let (match1, _) = PersistentRule.testPattern("doppler secrets*", isRegex: false, against: "doppler secrets --only-names")
        XCTAssertTrue(match1, "Glob blocks the safe variant too — no way to exclude")

        // Regex with negative lookahead
        let (match2, _) = PersistentRule.testPattern("doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, against: "doppler secrets --only-names")
        XCTAssertFalse(match2, "Regex excludes the safe --only-names variant")

        let (match3, _) = PersistentRule.testPattern("doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, against: "doppler secrets -p myproject")
        XCTAssertTrue(match3, "Regex still blocks the unsafe variant")
    }

    // MARK: - Bypass: word boundary (glob matches partial words)

    func testGlobMatchesPartialWords() {
        // Glob: "curl*" — intended to block curl commands
        // False positive: matches "curling_scores" or other words starting with curl
        let (globMatch, _) = PersistentRule.testPattern("curl*", isRegex: false, against: "curling_scores --output results.txt")
        XCTAssertTrue(globMatch, "Glob false positive — matches 'curling' not just 'curl'")

        // Regex with word boundary
        let (regexMatch, _) = PersistentRule.testPattern("\\bcurl\\b", isRegex: true, against: "curling_scores --output results.txt")
        XCTAssertFalse(regexMatch, "Regex word boundary avoids false positive")
    }

    // MARK: - Bypass: case sensitivity

    func testGlobIsCaseSensitive() {
        // Glob: "DELETE*" — intended to catch SQL deletes
        let (globMatch, _) = PersistentRule.testPattern("DELETE*", isRegex: false, against: "delete from users where id = 1")
        XCTAssertFalse(globMatch, "Glob is case-sensitive — misses lowercase")

        // Regex is compiled with .caseInsensitive
        let (regexMatch, _) = PersistentRule.testPattern("\\bDELETE\\b", isRegex: true, against: "delete from users where id = 1")
        XCTAssertTrue(regexMatch, "Regex case-insensitive flag catches both")
    }

    // MARK: - Glob strength: simplicity for common cases

    func testGlobWorksForSimplePrefixMatching() {
        // Glob shines for simple "command prefix" patterns
        let (m1, _) = PersistentRule.testPattern("swift build*", isRegex: false, against: "swift build -c release")
        let (m2, _) = PersistentRule.testPattern("git status*", isRegex: false, against: "git status --short")
        let (m3, _) = PersistentRule.testPattern("npm test*", isRegex: false, against: "npm test -- --coverage")
        XCTAssertTrue(m1)
        XCTAssertTrue(m2)
        XCTAssertTrue(m3, "Glob is fine for simple prefix matching")
    }

    func testGlobWorksForFileExtensionMatching() {
        let (m1, _) = PersistentRule.testPattern("*.yml", isRegex: false, against: "config/production.yml")
        let (m2, _) = PersistentRule.testPattern("*/production.*", isRegex: false, against: "config/production.yml")
        XCTAssertTrue(m1)
        XCTAssertTrue(m2, "Glob handles file extensions well")
    }

    // MARK: - Auto-detection: looksLikeRegex

    func testDetectsCharacterClassEscapes() {
        XCTAssertTrue(PatternCompiler.looksLikeRegex(#"doppler\s+secrets"#))
        XCTAssertTrue(PatternCompiler.looksLikeRegex(#"\w+@\w+"#))
        XCTAssertTrue(PatternCompiler.looksLikeRegex(#"\bkill\b"#))
        XCTAssertTrue(PatternCompiler.looksLikeRegex(#"file\d+"#))
    }

    func testDetectsGroupingAndAlternation() {
        XCTAssertTrue(PatternCompiler.looksLikeRegex("(npm|yarn) publish"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex("secrets_(get|download)"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex("foo|bar"))
    }

    func testDetectsQuantifiers() {
        XCTAssertTrue(PatternCompiler.looksLikeRegex("a+b"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex("colou?r"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex(#"x{2,5}"#))
    }

    func testDetectsCharacterClasses() {
        XCTAssertTrue(PatternCompiler.looksLikeRegex("[a-z]+"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex("[0-9]"))
    }

    func testDetectsAnchors() {
        XCTAssertTrue(PatternCompiler.looksLikeRegex("^start"))
        XCTAssertTrue(PatternCompiler.looksLikeRegex("end$"))
    }

    func testGlobPatternsNotFlaggedAsRegex() {
        XCTAssertFalse(PatternCompiler.looksLikeRegex("swift build*"))
        XCTAssertFalse(PatternCompiler.looksLikeRegex("*.yml"))
        XCTAssertFalse(PatternCompiler.looksLikeRegex("git status*"))
        XCTAssertFalse(PatternCompiler.looksLikeRegex("Sources/Gavel/*"))
        XCTAssertFalse(PatternCompiler.looksLikeRegex("*"))
    }
}
