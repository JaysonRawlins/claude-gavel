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
}
