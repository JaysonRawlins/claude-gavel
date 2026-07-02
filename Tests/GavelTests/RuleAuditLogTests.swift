import XCTest

@testable import Gavel

final class RuleAuditLogTests: XCTestCase {
    private var dir: String!
    private var path: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "audit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/rules.audit.jsonl"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testChainLinksAndVerifies() {
        let log = RuleAuditLog(path: path)
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "a", verdict: "block")
        log.record(action: "rule_removed", origin: "panel", toolName: "Bash", pattern: "a", verdict: "block")
        log.record(action: "rule_added", origin: "import", toolName: "*", pattern: "b", verdict: "prompt")

        let entries = log.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].prev, RuleAuditLog.genesisHash)
        XCTAssertEqual(entries[1].prev, entries[0].hash)
        XCTAssertEqual(entries[2].prev, entries[1].hash)
        XCTAssertEqual(entries.map(\.seq), [1, 2, 3])
        XCTAssertNil(log.verifyChain())
    }

    func testChainSurvivesReopen() {
        let first = RuleAuditLog(path: path)
        first.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "a", verdict: "block")

        let reopened = RuleAuditLog(path: path)
        reopened.record(action: "rule_removed", origin: "panel", toolName: "Bash", pattern: "a", verdict: "block")

        XCTAssertNil(reopened.verifyChain())
        XCTAssertEqual(reopened.entries().count, 2)
        XCTAssertEqual(reopened.entries()[1].prev, reopened.entries()[0].hash)
    }

    func testTamperedLineBreaksChain() throws {
        let log = RuleAuditLog(path: path)
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "safe", verdict: "block")
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "second", verdict: "prompt")

        // Attacker rewrites history: change entry 1's pattern in place.
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let tampered = text.replacingOccurrences(of: "safe", with: "evil")
        try tampered.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(RuleAuditLog(path: path).verifyChain(), 1)
    }

    func testDeletedMiddleLineBreaksChain() throws {
        let log = RuleAuditLog(path: path)
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "one", verdict: "block")
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "two", verdict: "block")
        log.record(action: "rule_added", origin: "panel", toolName: "Bash", pattern: "three", verdict: "block")

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
        let withoutMiddle = [lines[0], lines[2]].joined(separator: "\n") + "\n"
        try withoutMiddle.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(RuleAuditLog(path: path).verifyChain(), 3)
    }

    func testRuleStoreMutationsAreAudited() throws {
        let configPath = dir + "/rules.json"
        let store = RuleStore(configPath: configPath)
        let audit = try XCTUnwrap(store.auditLog)

        let rule = PersistentRule(toolName: "Bash", pattern: "audit-me", verdict: .block)
        store.addRule(rule, origin: "test")
        store.updateRule(id: rule.id, pattern: "audit-me-2", isRegex: false, verdict: .block, explanation: nil, origin: "test")
        store.setDisabled(id: rule.id, isDisabled: true, origin: "test")
        store.removeRule(id: rule.id, origin: "test")

        let actions = audit.entries().map(\.action)
        XCTAssertEqual(actions, ["rule_added", "rule_updated", "rule_disabled", "rule_removed"])
        XCTAssertTrue(audit.entries().allSatisfy { $0.origin == "test" })
        XCTAssertNil(audit.verifyChain())
    }

    func testDevNullConfigSkipsAudit() {
        XCTAssertNil(RuleStore(configPath: "/dev/null").auditLog)
    }
}
