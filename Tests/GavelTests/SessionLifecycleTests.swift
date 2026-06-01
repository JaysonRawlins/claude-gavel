import XCTest
@testable import Gavel

/// Tombstone lifecycle: live → dead migration, promotion back to live,
/// per-row forget, bulk clear, and persistence round-trip.
final class SessionLifecycleTests: XCTestCase {

    private var tmpHome: URL!
    private var manager: SessionManager!

    /// Stands in a live result for the test runner's own PID; everything else uses the real cwd check.
    private let liveOnOwnPid: (Int, String?) -> Bool = { pid, cwd in
        pid == Int(getpid()) ? true : SessionManager.defaultLiveness(pid: pid, cwd: cwd)
    }

    /// A PID effectively guaranteed not to exist on macOS. macOS reserves up
    /// to ~99999; anything above that range is unused by any real process.
    private let deadPid = 1_999_999

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        manager = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false, liveness: liveOnOwnPid)
    }

    override func tearDown() {
        manager = nil
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    // MARK: - Migration

    func testDeadSessionWithSessionIdMigratesToTombstone() {
        let sid = "test-session-uuid-1"
        let session = manager.session(for: deadPid)
        session.sessionId = sid
        session.cwd = "/tmp/test-project"

        manager.cleanupDeadSessions()

        XCTAssertNil(manager.sessions[deadPid], "Live dict should drop the dead PID")
        XCTAssertNotNil(manager.deadSessions[sid], "Tombstone should appear keyed by sessionId")
        XCTAssertEqual(manager.deadSessions[sid]?.cwd, "/tmp/test-project")
    }

    func testDeadSessionWithoutSessionIdIsDropped() {
        let session = manager.session(for: deadPid)
        session.cwd = "/tmp/test-project"
        // No sessionId set — not resumable.

        manager.cleanupDeadSessions()

        XCTAssertNil(manager.sessions[deadPid], "Live dict should drop")
        XCTAssertTrue(manager.deadSessions.isEmpty, "No sessionId means no tombstone")
    }

    // MARK: - PID reuse

    func testDefaultLivenessRejectsLivePidWithMismatchedCwd() {
        let livePid = Int(getpid())
        let realCwd = ProcessTree.cwd(of: Int32(livePid))
        XCTAssertNotNil(realCwd, "Test runner must have a readable cwd for this to be meaningful")

        XCTAssertTrue(
            SessionManager.defaultLiveness(pid: livePid, cwd: realCwd),
            "A live PID still in its recorded cwd is alive"
        )
        XCTAssertFalse(
            SessionManager.defaultLiveness(pid: livePid, cwd: (realCwd ?? "") + "/somewhere-else"),
            "A live PID whose cwd drifted from the recorded one was reused — dead"
        )
    }

    func testCleanupTombstonesPidReusedUnderDifferentCwd() {
        manager.livenessCheck = SessionManager.defaultLiveness
        let sid = "uuid-reused-pid"
        let session = manager.session(for: Int(getpid()))
        session.sessionId = sid
        session.cwd = "/tmp/some-other-recorded-path"

        manager.cleanupDeadSessions()

        XCTAssertNil(manager.sessions[Int(getpid())], "PID whose cwd no longer matches must leave the live dict")
        XCTAssertNotNil(manager.deadSessions[sid], "It must tombstone so the row flips to asleep")
    }

    // MARK: - Removal controls

    func testForgetTombstoneRemovesOnlyThatEntry() {
        let sidA = "uuid-A"
        let sidB = "uuid-B"
        let sessA = manager.session(for: deadPid)
        sessA.sessionId = sidA
        let sessB = manager.session(for: deadPid + 1)
        sessB.sessionId = sidB
        manager.cleanupDeadSessions()
        XCTAssertEqual(manager.deadSessions.count, 2)

        manager.forgetTombstone(sessionId: sidA)

        XCTAssertNil(manager.deadSessions[sidA])
        XCTAssertNotNil(manager.deadSessions[sidB])
    }

    func testClearDeadSessionsEmptiesTombstonesOnly() {
        let sid = "uuid-1"
        let dead = manager.session(for: deadPid)
        dead.sessionId = sid
        manager.cleanupDeadSessions()
        XCTAssertEqual(manager.deadSessions.count, 1)

        // Live session (own PID is alive — XCTest is running)
        let livePid = Int(getpid())
        _ = manager.session(for: livePid)
        XCTAssertNotNil(manager.sessions[livePid])

        manager.clearDeadSessions()

        XCTAssertTrue(manager.deadSessions.isEmpty)
        XCTAssertNotNil(manager.sessions[livePid], "Live session must survive clearDead")
    }

    // MARK: - Promotion

    func testRecordSessionIdPromotesMatchingTombstoneToLive() {
        let sid = "uuid-promote"
        let original = manager.session(for: deadPid)
        original.sessionId = sid
        manager.cleanupDeadSessions()
        XCTAssertNotNil(manager.deadSessions[sid])

        // Simulate a new live `claude --resume <sid>` arriving on a different PID.
        let newPid = Int(getpid())
        let revived = manager.session(for: newPid)
        manager.recordSessionId(sid, on: revived)

        // recordSessionId mutates @Published sessionId via DispatchQueue.main.async
        // so the binding plumbing matches SwiftUI's main-thread invariant.
        // Drain the main queue before asserting.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertNil(manager.deadSessions[sid], "Tombstone must be removed on resume")
        XCTAssertEqual(manager.sessions[newPid]?.sessionId, sid)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripsBothLiveAndDead() {
        let sidDead = "uuid-dead"
        let sidLive = "uuid-live"

        // Live session keyed on this test process's own PID so the reload
        // path classifies it as alive.
        let livePid = Int(getpid())
        let live = manager.session(for: livePid)
        live.sessionId = sidLive
        live.cwd = "/tmp/live-project"
        live.label = "my live one"
        manager.recordSessionId(sidLive, on: live)

        // Dead session: insert + migrate.
        let dead = manager.session(for: deadPid)
        dead.sessionId = sidDead
        dead.cwd = "/tmp/dead-project"
        manager.cleanupDeadSessions()

        manager.saveActiveSessions()

        // Spin up a fresh manager pointing at the same tmp home.
        let reloaded = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false, liveness: liveOnOwnPid)

        XCTAssertNotNil(reloaded.sessions[livePid], "Live session must rehydrate")
        XCTAssertEqual(reloaded.sessions[livePid]?.sessionId, sidLive)
        XCTAssertNotNil(reloaded.deadSessions[sidDead], "Tombstone must rehydrate")
        XCTAssertEqual(reloaded.deadSessions[sidDead]?.cwd, "/tmp/dead-project")
        XCTAssertFalse(reloaded.deadSessions[sidDead]?.isAlive ?? true)
    }

    func testCodexAgentAssignedOnSessionCreation() {
        let pid = Int(getpid())
        let claudeSession = manager.session(for: pid)
        XCTAssertEqual(claudeSession.agent, .claude, "Default agent should be claude")

        let otherPid = 1_999_998
        let codexSession = manager.session(for: otherPid, agent: .codex)
        XCTAssertEqual(codexSession.agent, .codex)
    }

    func testAgentPersistsAcrossDaemonRestart() {
        let pid = Int(getpid())
        let session = manager.session(for: pid, agent: .codex)
        session.sessionId = "codex-sid"
        manager.recordSessionId("codex-sid", on: session)
        manager.saveActiveSessions()

        let reloaded = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false, liveness: liveOnOwnPid)
        XCTAssertEqual(reloaded.sessions[pid]?.agent, .codex, "Codex agent must survive restart")
    }

    func testPersistenceBackwardCompatLegacyArrayFormat() throws {
        // Old format: bare array of live sessions, no tombstones.
        let livePid = Int(getpid())
        let legacy: [[String: Any]] = [
            ["pid": livePid, "sessionId": "legacy-sid", "cwd": "/tmp/legacy"]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let path = tmpHome.path + "/.claude/gavel/active-sessions.json"
        try? FileManager.default.createDirectory(
            atPath: tmpHome.path + "/.claude/gavel",
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: data)

        let reloaded = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false, liveness: liveOnOwnPid)

        XCTAssertEqual(reloaded.sessions[livePid]?.sessionId, "legacy-sid")
        XCTAssertTrue(reloaded.deadSessions.isEmpty, "Legacy format has no tombstones")
    }

    // MARK: - Compact summary

    func testCompactSummaryReflectsLiveAndAsleepCounts() {
        let vm = MonitorViewModel(sessionManager: manager, approvalCoordinator: ApprovalCoordinator())

        _ = manager.session(for: Int(getpid()))
        let dead = manager.session(for: deadPid)
        dead.sessionId = "compact-summary-uuid"
        manager.cleanupDeadSessions()

        let summary = vm.compactSummary
        XCTAssertTrue(summary.hasPrefix("Gavel"), summary)
        XCTAssertTrue(summary.contains("1 live"), summary)
        XCTAssertTrue(summary.contains("1 asleep"), summary)
    }
}
