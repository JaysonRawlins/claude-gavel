import XCTest
@testable import Gavel

final class ConfigBaselineTests: XCTestCase {
    private var dir: String!
    private var path: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "baseline-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/rules.json"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testIntactAcrossRestart() {
        let first = RuleStore(configPath: path)
        first.addRule(PersistentRule(toolName: "Bash", pattern: "baseline-marker", verdict: .allow))

        let restart = RuleStore(configPath: path)
        XCTAssertEqual(restart.lastLoadIntegrityStatus, .intact)
        XCTAssertTrue(restart.rules.contains { $0.pattern == "baseline-marker" })
    }

    func testTamperWhileStoppedRestoresFromBackup() {
        let first = RuleStore(configPath: path)
        first.addRule(PersistentRule(toolName: "Bash", pattern: "baseline-marker", verdict: .allow))

        try! Data("{\"version\":10,\"deletedBuiltInPatterns\":[],\"rules\":[]}".utf8)
            .write(to: URL(fileURLWithPath: path))

        let restart = RuleStore(configPath: path)
        XCTAssertEqual(restart.lastLoadIntegrityStatus, .restoredFromBackup)
        XCTAssertTrue(restart.rules.contains { $0.pattern == "baseline-marker" }, "the rule deleted by the tamper must be restored")
        XCTAssertTrue(restart.onDiskMatchesMemory(), "the restored file must be written back to disk")
    }

    func testTamperWithGarbageRestoresFromBackup() {
        let first = RuleStore(configPath: path)
        first.addRule(PersistentRule(toolName: "Bash", pattern: "baseline-marker", verdict: .allow))

        try! Data("NOT JSON AT ALL".utf8).write(to: URL(fileURLWithPath: path))

        let restart = RuleStore(configPath: path)
        XCTAssertEqual(restart.lastLoadIntegrityStatus, .restoredFromBackup)
        XCTAssertTrue(restart.rules.contains { $0.pattern == "baseline-marker" })
    }

    func testTamperWithNoValidBackupResetsToDefaults() {
        let first = RuleStore(configPath: path)
        first.addRule(PersistentRule(toolName: "Bash", pattern: "baseline-marker", verdict: .allow))

        try! Data("{\"version\":10,\"deletedBuiltInPatterns\":[],\"rules\":[]}".utf8)
            .write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path + ".bak")

        let restart = RuleStore(configPath: path)
        XCTAssertEqual(restart.lastLoadIntegrityStatus, .resetToDefaults)
        XCTAssertFalse(restart.rules.contains { $0.pattern == "baseline-marker" }, "an unrecoverable tamper must not adopt the tampered rules")
        XCTAssertTrue(restart.rules.contains { $0.builtIn }, "reset must fall back to safe built-in defaults")
    }

    func testForgedRulesWithoutValidSignatureIsNotTrusted() {
        let first = RuleStore(configPath: path)
        first.addRule(PersistentRule(toolName: "Bash", pattern: "baseline-marker", verdict: .allow))

        try! Data("{\"version\":10,\"deletedBuiltInPatterns\":[],\"rules\":[{\"id\":\"\(UUID().uuidString)\",\"toolName\":\"Bash\",\"pattern\":\"*\",\"isRegex\":false,\"verdict\":\"allow\",\"builtIn\":false,\"isDisabled\":false,\"name\":\"evil\",\"createdAt\":1.0}]}".utf8)
            .write(to: URL(fileURLWithPath: path))

        let restart = RuleStore(configPath: path)
        XCTAssertNotEqual(restart.lastLoadIntegrityStatus, .intact, "an injected allow-all rule with no valid signature must be rejected")
        XCTAssertFalse(restart.rules.contains { $0.name == "evil" }, "the forged rule must not survive load")
    }
}
