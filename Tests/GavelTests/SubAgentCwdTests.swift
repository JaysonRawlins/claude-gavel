import XCTest

@testable import Gavel

/// Sub-agent PreToolUse payloads (agent_id set) can report an isolated
/// worktree as cwd. Recording that on the pid-keyed session repointed the
/// row/watcher/review links — and, before liveness moved to process start
/// time, made the cleanup timer read the session as a reused PID and
/// tombstone it, destroying per-session state like the remote-approval
/// grant (the "subagent approvals never mirror to Telegram" bug).
final class SubAgentCwdTests: XCTestCase {

    private var tmpHome: URL!
    private var manager: SessionManager!
    private var router: HookRouter!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-subagent-cwd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        manager = SessionManager(homeDir: tmpHome, autoStartTimers: false, autoDiscover: false)
        let engine = ApprovalEngine(ruleStore: RuleStore(configPath: "/dev/null"))
        router = HookRouter(
            sessionManager: manager, approvalEngine: engine,
            approvalCoordinator: ApprovalCoordinator())
    }

    override func tearDown() {
        router = nil
        manager = nil
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    private func bashEvent(pid: Int, cwd: String, agentId: String?) -> Data {
        let agentField = agentId.map { "\"agent_id\": \"\($0)\"," } ?? ""
        return """
            {
                "hookType": "PreToolUse",
                "sessionPid": \(pid),
                "timestamp": 1712600000.0,
                "payload": {
                    "type": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "ls"},
                    "session_id": "subagent-cwd-test",
                    \(agentField)
                    "cwd": "\(cwd)"
                }
            }
            """.data(using: .utf8)!
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }

    func testSubAgentCwdDoesNotOverwriteSessionCwd() {
        let session = manager.session(for: 72001)
        session.isAutoApproveEnabled = true
        session.cwd = "/tmp/main-project"

        router.handle(
            data: bashEvent(
                pid: 72001, cwd: "/tmp/main-project/.claude/worktrees/agent-abc",
                agentId: "agent-abc"),
            respond: { _ in })
        drainMainQueue()

        XCTAssertEqual(
            session.cwd, "/tmp/main-project",
            "A sub-agent's worktree cwd must not repoint the session")
    }

    func testMainPayloadCwdStillUpdatesSessionCwd() {
        let session = manager.session(for: 72002)
        session.isAutoApproveEnabled = true
        session.cwd = "/tmp/old-project"

        router.handle(
            data: bashEvent(pid: 72002, cwd: "/tmp/new-project", agentId: nil),
            respond: { _ in })
        drainMainQueue()

        XCTAssertEqual(
            session.cwd, "/tmp/new-project",
            "Main-conversation cwd updates must keep flowing")
    }
}
