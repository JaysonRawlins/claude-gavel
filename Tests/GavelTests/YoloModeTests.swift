import XCTest
@testable import Gavel

final class YoloModeTests: XCTestCase {
    var session: Session!
    var tmpDir: URL!
    var planPath: String!

    override func setUp() {
        session = Session(pid: 12345)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(".claude/plans/yolo-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        planPath = tmpDir.appendingPathComponent("2026-05-21_plan.md").path
        try? "# Initial plan\n".write(toFile: planPath, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let parent = tmpDir?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func payload(tool: String = "Bash", command: String? = nil, filePath: String? = nil) -> PreToolUsePayload {
        var input: [String: AnyCodable] = [:]
        if let c = command { input["command"] = AnyCodable(c) }
        if let f = filePath { input["file_path"] = AnyCodable(f) }
        return PreToolUsePayload(toolName: tool, toolInput: input)
    }

    private func waitForMain() {
        let exp = expectation(description: "main queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - canEngage / engage

    func testCanEngageReturnsFalseWhenNoPlan() {
        let (ok, reason) = YoloMode.canEngage(session: session)
        XCTAssertFalse(ok)
        XCTAssertNotNil(reason)
    }

    func testCanEngageReturnsTrueWhenPlanExists() {
        session.lastPlanPath = planPath
        let (ok, reason) = YoloMode.canEngage(session: session)
        XCTAssertTrue(ok)
        XCTAssertNil(reason)
    }

    func testCanEngageReturnsFalseWhenPlanFileDeleted() {
        session.lastPlanPath = planPath
        try? FileManager.default.removeItem(atPath: planPath)
        let (ok, reason) = YoloMode.canEngage(session: session)
        XCTAssertFalse(ok)
        XCTAssertNotNil(reason)
    }

    func testEngageCapturesPathAndHashAndFlipsSyncFlag() {
        session.lastPlanPath = planPath
        XCTAssertTrue(YoloMode.engage(session: session))
        XCTAssertTrue(session.isYoloActive, "sync flag must flip immediately on engage")
        waitForMain()
        XCTAssertEqual(session.yoloPlanPath, planPath)
        XCTAssertNotNil(session.yoloPlanHash)
        XCTAssertNotNil(session.yoloEngagedAt)
        XCTAssertTrue(session.isSubAgentInheritEnabled, "engage opts into sub-agent inheritance")
    }

    func testEngageFailsWithoutPlan() {
        XCTAssertFalse(YoloMode.engage(session: session))
        XCTAssertFalse(session.isYoloActive)
    }

    // MARK: - shouldHalt

    func testShouldHaltReturnsNilWhenNotEngaged() {
        let result = YoloMode.shouldHalt(session: session, payload: payload(tool: "Write", filePath: planPath))
        XCTAssertNil(result)
    }

    func testShouldHaltOnWriteToTrackedPlan() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        let result = YoloMode.shouldHalt(session: session, payload: payload(tool: "Write", filePath: planPath))
        XCTAssertEqual(result, "plan modified by agent")
    }

    func testShouldHaltOnEditToTrackedPlan() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        let result = YoloMode.shouldHalt(session: session, payload: payload(tool: "Edit", filePath: planPath))
        XCTAssertEqual(result, "plan modified by agent")
    }

    func testShouldHaltOnMultiEditToTrackedPlan() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        let result = YoloMode.shouldHalt(session: session, payload: payload(tool: "MultiEdit", filePath: planPath))
        XCTAssertEqual(result, "plan modified by agent")
    }

    func testReadOnTrackedPlanDoesNotHalt() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        let result = YoloMode.shouldHalt(session: session, payload: payload(tool: "Read", filePath: planPath))
        XCTAssertNil(result)
    }

    func testUnrelatedToolCallDoesNotHalt() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        let result = YoloMode.shouldHalt(session: session, payload: payload(command: "ls"))
        XCTAssertNil(result)
    }

    func testShouldHaltOnHashDrift() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        try? "# Mutated plan\n".write(toFile: planPath, atomically: true, encoding: .utf8)
        let result = YoloMode.shouldHalt(session: session, payload: payload(command: "ls"))
        XCTAssertEqual(result, "plan changed on disk")
    }

    func testShouldHaltOnPlanDeleted() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        try? FileManager.default.removeItem(atPath: planPath)
        let result = YoloMode.shouldHalt(session: session, payload: payload(command: "ls"))
        XCTAssertEqual(result, "plan deleted")
    }

    // MARK: - disengage

    func testDisengageClearsStateAndSetsReason() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        YoloMode.disengage(session: session, reason: "test reason")
        XCTAssertFalse(session.isYoloActive, "sync flag must flip immediately on disengage")
        waitForMain()
        XCTAssertNil(session.yoloEngagedAt)
        XCTAssertNil(session.yoloPlanPath)
        XCTAssertNil(session.yoloPlanHash)
        XCTAssertEqual(session.yoloDisabledReason, "test reason")
    }

    func testRevokeAutoApproveClearsYoloIncludingReason() {
        session.lastPlanPath = planPath
        YoloMode.engage(session: session)
        waitForMain()
        YoloMode.disengage(session: session, reason: "halt")
        waitForMain()
        XCTAssertEqual(session.yoloDisabledReason, "halt")
        session.revokeAutoApprove()
        XCTAssertNil(session.yoloDisabledReason, "revoke is a full reset — reason cleared too")
        XCTAssertFalse(session.isYoloActive)
    }

    // MARK: - isPlanPath

    func testIsPlanPathMatchesStandardPlan() {
        let home = NSHomeDirectory()
        XCTAssertTrue(YoloMode.isPlanPath("\(home)/.claude/plans/yolo-mode/2026-05-21_plan.md"))
        XCTAssertTrue(YoloMode.isPlanPath("\(home)/.claude/plans/anything/whatever.md"))
    }

    func testIsPlanPathRejectsNonPlanPaths() {
        let home = NSHomeDirectory()
        XCTAssertFalse(YoloMode.isPlanPath("\(home)/.claude/plans/foo.md"), "must be in a sub-folder")
        XCTAssertFalse(YoloMode.isPlanPath("\(home)/.claude/plans/folder/file.txt"), "must be .md")
        XCTAssertFalse(YoloMode.isPlanPath("\(home)/.claude/settings.json"))
        XCTAssertFalse(YoloMode.isPlanPath("/tmp/whatever.md"))
    }

    // MARK: - recentPlans

    func testRecentPlansListsOneLevelMarkdownNewestFirst() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("plans-enum-\(UUID().uuidString)", isDirectory: true)
        let alpha = base.appendingPathComponent("alpha", isDirectory: true)
        let beta = base.appendingPathComponent("beta", isDirectory: true)
        let nested = alpha.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: beta, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let older = alpha.appendingPathComponent("old-plan.md")
        let newer = beta.appendingPathComponent("new-plan.md")
        try "old".write(to: older, atomically: true, encoding: .utf8)
        try "new".write(to: newer, atomically: true, encoding: .utf8)
        try "x".write(to: alpha.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: nested.appendingPathComponent("buried.md"), atomically: true, encoding: .utf8)
        try "x".write(to: base.appendingPathComponent("loose.md"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let plans = YoloMode.recentPlans(in: base)
        XCTAssertEqual(plans.map { $0.filename }, ["new-plan.md", "old-plan.md"], "newest-modified first, one level only")
        XCTAssertEqual(plans.first?.folder, "beta")
        XCTAssertFalse(plans.contains { $0.filename == "notes.txt" }, "non-.md excluded")
        XCTAssertFalse(plans.contains { $0.filename == "buried.md" }, "deeper than one level excluded")
        XCTAssertFalse(plans.contains { $0.filename == "loose.md" }, "flat plans/*.md excluded")
    }

    func testRecentPlansHonorsLimit() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("plans-limit-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("proj", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for i in 0..<5 {
            try "p".write(to: folder.appendingPathComponent("plan-\(i).md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(YoloMode.recentPlans(in: base, limit: 3).count, 3)
    }

    func testRecentPlansEmptyWhenDirMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(YoloMode.recentPlans(in: missing).isEmpty)
    }

    func testEngageAfterManualArmFreezesPlanAndHaltsOnWrite() {
        session.lastPlanPath = planPath
        XCTAssertTrue(YoloMode.engage(session: session))
        waitForMain()
        XCTAssertEqual(session.yoloPlanPath, planPath, "manually-armed path is frozen identically to auto-detect")
        XCTAssertEqual(
            YoloMode.shouldHalt(session: session, payload: payload(tool: "Write", filePath: planPath)),
            "plan modified by agent"
        )
    }
}
