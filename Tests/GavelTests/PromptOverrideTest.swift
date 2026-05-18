import XCTest
@testable import Gavel

/// HookRouter coverage for the two session-allow paths: pattern-bound SessionRule (narrow) and rule-suppression by ID (covers the rule's full regex scope, e.g. one prompt rule spanning many MCP tools).
final class PromptOverrideTest: XCTestCase {
    private func runRouter(
        session: Session,
        store: RuleStore,
        toolName: String = "Bash",
        toolInputJson: String
    ) -> [String: Any]? {
        let engine = ApprovalEngine(patternMatcher: PatternMatcher(), ruleStore: store)
        let manager = SessionManager()
        let live = manager.session(for: session.pid)
        live.sessionRules = session.sessionRules
        live.suppressedRuleIds = session.suppressedRuleIds
        let coordinator = ApprovalCoordinator()
        let router = HookRouter(sessionManager: manager, approvalEngine: engine, approvalCoordinator: coordinator)

        let json = """
        {
            "hookType": "PreToolUse",
            "sessionPid": \(session.pid),
            "timestamp": 1712600000.0,
            "payload": {
                "type": "PreToolUse",
                "tool_name": "\(toolName)",
                "tool_input": \(toolInputJson),
                "session_id": "test-session"
            }
        }
        """

        var responseJson: [String: Any]?
        router.handle(data: json.data(using: .utf8)!) { data in
            responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return responseJson
    }

    private func bashInput(_ command: String) -> String {
        "{\"command\": \"\(command)\"}"
    }

    func testSessionAllowOverridesUserPromptRule() {
        let path = NSTemporaryDirectory() + "promptoverride-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "git push*", verdict: .prompt))

        let session = Session(pid: 88881)
        session.sessionRules.append(SessionRule(toolName: "Bash", pattern: "git push*"))

        let response = runRouter(session: session, store: store, toolInputJson: bashInput("git push origin main"))
        XCTAssertEqual(response?["verdict"] as? String, "allow",
                       "Session allow should override user always-prompt rule. Got: \(String(describing: response))")
    }

    func testSessionAllowOverridesBuiltInPromptRule() {
        let path = NSTemporaryDirectory() + "promptoverride-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RuleStore(configPath: path)
        store.addRule(PersistentRule(toolName: "Bash", pattern: "git push*", isRegex: false, verdict: .prompt, builtIn: true))

        let session = Session(pid: 88882)
        session.sessionRules.append(SessionRule(toolName: "Bash", pattern: "git push*"))

        let response = runRouter(session: session, store: store, toolInputJson: bashInput("git push origin main"))
        XCTAssertEqual(response?["verdict"] as? String, "allow",
                       "Session allow should override built-in prompt rule. Got: \(String(describing: response))")
    }

    func testSuppressedRuleCoversSiblingMcpToolNames() {
        let path = NSTemporaryDirectory() + "promptoverride-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RuleStore(configPath: path)

        let rule = PersistentRule(
            toolName: "*",
            pattern: "mcp__.*[Pp]laywright.*(navigate|evaluate|click|type)",
            isRegex: true,
            verdict: .prompt
        )
        store.addRule(rule)

        let session = Session(pid: 88883)
        session.suppressedRuleIds.insert(rule.id)

        let r1 = runRouter(session: session, store: store, toolName: "mcp__Playwright__browser_click", toolInputJson: "{}")
        XCTAssertEqual(r1?["verdict"] as? String, "allow")

        let r2 = runRouter(session: session, store: store, toolName: "mcp__Playwright__browser_navigate", toolInputJson: "{}")
        XCTAssertEqual(r2?["verdict"] as? String, "allow")

        let r3 = runRouter(session: session, store: store, toolName: "mcp__Playwright__browser_type", toolInputJson: "{}")
        XCTAssertEqual(r3?["verdict"] as? String, "allow")
    }

    func testPatternBoundSessionRuleDoesNotCoverSiblings() {
        let path = NSTemporaryDirectory() + "promptoverride-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RuleStore(configPath: path)

        store.addRule(PersistentRule(
            toolName: "*",
            pattern: "mcp__.*[Pp]laywright.*",
            isRegex: true,
            verdict: .prompt
        ))

        let session = Session(pid: 88884)

        session.sessionRules.append(SessionRule(toolName: "mcp__Playwright__browser_click", pattern: "*"))

        let click = runRouter(session: session, store: store, toolName: "mcp__Playwright__browser_click", toolInputJson: "{}")
        XCTAssertEqual(click?["verdict"] as? String, "allow", "Same tool name should match the pattern-bound rule")

        let navRule = SessionRule(toolName: "mcp__Playwright__browser_click", pattern: "*")
        XCTAssertNil(
            navRule.matches(toolName: "mcp__Playwright__browser_navigate", command: nil, filePath: nil) ? navRule : nil,
            "Pattern-bound rule for click should not match navigate"
        )
    }

    func testRevokeAutoApproveClearsSuppressedRules() {
        let session = Session(pid: 88885)
        session.suppressedRuleIds.insert(UUID())
        session.suppressedRuleIds.insert(UUID())
        XCTAssertEqual(session.suppressedRuleIds.count, 2)
        session.revokeAutoApprove()
        XCTAssertTrue(session.suppressedRuleIds.isEmpty)
    }
}
