import XCTest
@testable import Gavel

final class ConfigWatcherTests: XCTestCase {
    func testEvaluateRevertsAndAlertsWhenTampered() {
        var restored = 0
        var alerted = 0
        let watcher = ConfigWatcher(
            path: "/tmp/unused",
            isIntact: { false },
            restore: { restored += 1 },
            onTamper: { alerted += 1 }
        )
        watcher.evaluateOnce()
        XCTAssertEqual(restored, 1, "a mismatched file must be restored")
        XCTAssertEqual(alerted, 1, "a tamper must raise exactly one alert")
    }

    func testEvaluateIsNoOpWhenIntact() {
        var restored = 0
        var alerted = 0
        let watcher = ConfigWatcher(
            path: "/tmp/unused",
            isIntact: { true },
            restore: { restored += 1 },
            onTamper: { alerted += 1 }
        )
        watcher.evaluateOnce()
        XCTAssertEqual(restored, 0, "an intact file must not be rewritten")
        XCTAssertEqual(alerted, 0, "an intact file must not alert (no false positive on the daemon's own write)")
    }
}

final class RuleStoreIntegrityTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "rulestore-integrity-\(UUID().uuidString).json"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testOnDiskMatchesMemoryAfterSave() {
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "tier2-marker", verdict: .allow))
        XCTAssertTrue(store.onDiskMatchesMemory(), "on-disk must match memory right after a save")
    }

    func testOnDiskMismatchAfterExternalTamper() {
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "tier2-marker", verdict: .allow))
        try? Data("CORRUPTED".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertFalse(store.onDiskMatchesMemory(), "an out-of-band write must read as a mismatch")
    }

    func testReassertRestoresFromMemory() {
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "tier2-marker", verdict: .allow))
        try? Data("CORRUPTED".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertFalse(store.onDiskMatchesMemory())

        store.reassertOnDisk()

        XCTAssertTrue(store.onDiskMatchesMemory(), "reassert must rewrite the file from memory")
        let reloaded = RuleStore(configPath: path)
        XCTAssertTrue(reloaded.rules.contains { $0.pattern == "tier2-marker" }, "restored file must decode back to the known-good rules")
    }

    func testOnDiskMismatchWhenFileMissing() {
        let store = RuleStore(configPath: path)
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertFalse(store.onDiskMatchesMemory(), "a deleted file must read as a mismatch so the watcher recreates it")
    }

    func testOnDiskMatchesMemoryIgnoresFormattingAndKeyOrder() {
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "fmt-marker", verdict: .allow))

        let raw = FileManager.default.contents(atPath: path)!
        let decoded = try! JSONDecoder().decode(RulesFile.self, from: raw)
        let reformatted = try! JSONEncoder().encode(decoded)
        try! reformatted.write(to: URL(fileURLWithPath: path))

        XCTAssertNotEqual(reformatted, raw, "precondition: a different encoder produces different bytes")
        XCTAssertTrue(store.onDiskMatchesMemory(), "same data with different formatting/key order must NOT read as tamper")
    }
}
