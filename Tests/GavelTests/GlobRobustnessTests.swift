import XCTest
@testable import Gavel

/// Glob bypass scenarios regex handles — flag insertion, traversal, whitespace, alternation, word boundary, case, negative lookahead.
final class GlobRobustnessTests: XCTestCase {
    func testGlobBypassWithInsertedFlags() {
        let (globMatch, _) = PersistentRule.testPattern("docker push*", isRegex: false, against: "docker --config /tmp/evil push myimage")
        XCTAssertFalse(globMatch, "Glob misses flag insertion between command and subcommand")

        let (regexMatch, _) = PersistentRule.testPattern("\\bdocker\\b.*\\bpush\\b", isRegex: true, against: "docker --config /tmp/evil push myimage")
        XCTAssertTrue(regexMatch, "Regex catches flag insertion")
    }

    func testGlobBypassWithPathTraversal() {
        let (match1, _) = PersistentRule.testPattern("Sources/*", isRegex: false, against: "Sources/../../../etc/passwd")
        XCTAssertTrue(match1, "Glob matches traversal — it can't distinguish safe vs malicious paths")

        let (match2, _) = PersistentRule.testPattern("^Sources/(?!.*\\.\\.)", isRegex: true, against: "Sources/../../../etc/passwd")
        XCTAssertFalse(match2, "Regex with negative lookahead rejects traversal")
    }

    func testGlobBypassWithTabs() {
        let (globMatch, _) = PersistentRule.testPattern("rm -rf *", isRegex: false, against: "rm\t-rf /important")
        XCTAssertFalse(globMatch, "Glob misses tab-separated arguments")

        let (regexMatch, _) = PersistentRule.testPattern("\\brm\\s+-rf\\b", isRegex: true, against: "rm\t-rf /important")
        XCTAssertTrue(regexMatch, "Regex \\s+ matches tabs")
    }

    func testGlobCannotExpressAlternation() {
        let (npmMatch, _) = PersistentRule.testPattern("npm publish*", isRegex: false, against: "npm publish --tag latest")
        let (yarnMatch, _) = PersistentRule.testPattern("npm publish*", isRegex: false, against: "yarn publish --tag latest")
        XCTAssertTrue(npmMatch)
        XCTAssertFalse(yarnMatch, "Single glob can't match both npm and yarn")

        let (regexNpm, _) = PersistentRule.testPattern("(npm|yarn)\\s+publish", isRegex: true, against: "npm publish --tag latest")
        let (regexYarn, _) = PersistentRule.testPattern("(npm|yarn)\\s+publish", isRegex: true, against: "yarn publish --tag latest")
        XCTAssertTrue(regexNpm)
        XCTAssertTrue(regexYarn, "Regex alternation matches both")
    }

    func testGlobCannotExpressExceptions() {
        let (match1, _) = PersistentRule.testPattern("doppler secrets*", isRegex: false, against: "doppler secrets --only-names")
        XCTAssertTrue(match1, "Glob blocks the safe variant too — no way to exclude")

        let (match2, _) = PersistentRule.testPattern("doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, against: "doppler secrets --only-names")
        XCTAssertFalse(match2, "Regex excludes the safe --only-names variant")

        let (match3, _) = PersistentRule.testPattern("doppler\\s+secrets\\b(?!.*--only-names)", isRegex: true, against: "doppler secrets -p myproject")
        XCTAssertTrue(match3, "Regex still blocks the unsafe variant")
    }

    func testGlobMatchesPartialWords() {
        let (globMatch, _) = PersistentRule.testPattern("curl*", isRegex: false, against: "curling_scores --output results.txt")
        XCTAssertTrue(globMatch, "Glob false positive — matches 'curling' not just 'curl'")

        let (regexMatch, _) = PersistentRule.testPattern("\\bcurl\\b", isRegex: true, against: "curling_scores --output results.txt")
        XCTAssertFalse(regexMatch, "Regex word boundary avoids false positive")
    }

    func testGlobIsCaseSensitive() {
        let (globMatch, _) = PersistentRule.testPattern("DELETE*", isRegex: false, against: "delete from users where id = 1")
        XCTAssertFalse(globMatch, "Glob is case-sensitive — misses lowercase")

        let (regexMatch, _) = PersistentRule.testPattern("\\bDELETE\\b", isRegex: true, against: "delete from users where id = 1")
        XCTAssertTrue(regexMatch, "Regex case-insensitive flag catches both")
    }

    func testGlobWorksForSimplePrefixMatching() {
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
