import XCTest

@testable import Gavel

/// Full-command review page + Telegram proposal adjudication.
final class CommandReviewTests: XCTestCase {

    private var server: DiffReviewServer!
    private var port: UInt16!
    private let owner: Int64 = 42

    override func setUpWithError() throws {
        server = DiffReviewServer()
        try server.start(port: 0)
        port = try XCTUnwrap(server.boundPort)
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    // MARK: - Helpers

    private func makeCommand(
        command: String? = "aws s3 cp s3://bucket/very-long-key /tmp/x --profile Prod-123",
        args: [CommandArg] = [],
        withheldInline: Bool = false,
        offersScopedAllow: Bool = false
    ) -> CommandContent {
        CommandContent(
            sessionLabel: "argscope",
            toolName: command != nil ? "Bash" : "mcp__Slack__read_history",
            cwd: "/Users/x/code/project",
            command: command,
            args: args,
            triggerReason: "Default rule: something fired",
            withheldInline: withheldInline,
            offersScopedAllow: offersScopedAllow)
    }

    /// Pump the main queue — proposal adjudication and rule authoring hop to
    /// main before mutating stores.
    private func drainMain() {
        let e = expectation(description: "main drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private struct HTTPResult {
        let status: Int
        let body: String
    }

    private func request(_ path: String, method: String = "GET", body: String? = nil) throws -> HTTPResult {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        req.httpMethod = method
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: HTTPResult?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = HTTPResult(
                    status: http.statusCode,
                    body: String(decoding: data ?? Data(), as: UTF8.self))
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 10) == .success else {
            throw XCTSkip("HTTP request timed out")
        }
        return try XCTUnwrap(result)
    }

    // MARK: - Command page rendering

    func testCommandPageRendersFullCommandUnredacted() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertEqual(res.status, 200)
        // The whole point: the FULL command, not the Telegram-truncated form.
        XCTAssertTrue(res.body.contains("aws s3 cp s3://bucket/very-long-key /tmp/x --profile Prod-123"))
        XCTAssertTrue(res.body.contains("argscope"))
        XCTAssertTrue(res.body.contains("/Users/x/code/project"))
        XCTAssertTrue(res.body.contains("Default rule: something fired"))
    }

    func testCommandPageRendersMCPArgs() throws {
        let resolvable = ResolvableApproval { _ in }
        let content = makeCommand(command: nil, args: [
            CommandArg(name: "channel", value: "general", scopable: true),
            CommandArg(name: "workspace", value: "defiance", scopable: true),
        ])
        let nonce = server.register(command: content, resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertTrue(res.body.contains("mcp__Slack__read_history"))
        XCTAssertTrue(res.body.contains("channel"))
        XCTAssertTrue(res.body.contains("general"))
        XCTAssertTrue(res.body.contains("workspace"))
        XCTAssertTrue(res.body.contains("defiance"))
    }

    func testCommandPageEscapesHTML() throws {
        let resolvable = ResolvableApproval { _ in }
        let content = makeCommand(command: "echo '<script>alert(1)</script>'")
        let nonce = server.register(command: content, resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertFalse(res.body.contains("<script>alert(1)</script>"))
        XCTAssertTrue(res.body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testWithheldBannerShownOnPage() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(command: makeCommand(withheldInline: true), resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertTrue(res.body.contains("Withheld from Telegram"))
    }

    // MARK: - Command page verdicts

    func testAllowVerdictResolvesWithNote() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow","note":"checked the profile"}"#)
        XCTAssertEqual(res.status, 200)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .allow)
        XCTAssertEqual(d.additionalContext?.contains("checked the profile"), true)
    }

    func testDenyVerdictCarriesNoteInReason() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"deny","note":"wrong account"}"#)
        XCTAssertEqual(res.status, 200)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .block)
        XCTAssertEqual(d.reason?.contains("wrong account"), true)
    }

    func testResolvedCommandPageStopsServingCommand() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        _ = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow"}"#)
        let page = try request("/review/\(nonce)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.body.contains("Already resolved"))
        XCTAssertFalse(page.body.contains("aws s3 cp"))
    }

    func testReviewedSignalMentionsFullCommand() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        // View the page first, then approve from another source (phone/Mac).
        _ = try request("/review/\(nonce)")
        _ = resolvable.resolve(Decision(verdict: .allow, reason: "Approved from phone"), from: .telegram)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.additionalContext?.contains("reviewed the full command"), true)
    }

    func testUnviewedApprovalHasNoReviewedSignal() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        _ = server.register(command: makeCommand(), resolvable: resolvable)

        _ = resolvable.resolve(Decision(verdict: .allow, reason: "Approved from phone"), from: .telegram)
        let d = try XCTUnwrap(decision)
        XCTAssertNil(d.additionalContext)
    }

    // MARK: - Telegram command-link button

    func testCommandURLButtonPresent() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(
            resolvable: approval, text: "body", allowSession: nil,
            commandURL: "https://mac.tail1234.ts.net:8443/review/xyz")

        let keyboard = try XCTUnwrap(fake.sentMessages.last?.keyboard)
        let first = try XCTUnwrap(keyboard.first?.first)
        XCTAssertEqual(first.text, "📄 Full command")
        XCTAssertEqual(first.url, "https://mac.tail1234.ts.net:8443/review/xyz")
        XCTAssertNil(first.callbackData)
    }

    func testWithheldCommandURLButtonRelabeled() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(
            resolvable: approval, text: "body", withheld: true, allowSession: nil,
            commandURL: "https://mac.tail1234.ts.net:8443/review/xyz")

        let keyboard = try XCTUnwrap(fake.sentMessages.last?.keyboard)
        XCTAssertEqual(keyboard.first?.first?.text, "🔒 View full command")
    }

    func testReviewAndCommandLinksShareTheLeadingRow() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(
            resolvable: approval, text: "commit?", allowSession: nil,
            reviewURL: "https://mac.tail1234.ts.net:8443/review/diff1",
            commandURL: "https://mac.tail1234.ts.net:8443/review/cmd1")

        let keyboard = try XCTUnwrap(fake.sentMessages.last?.keyboard)
        let linkRow = try XCTUnwrap(keyboard.first)
        XCTAssertEqual(linkRow.map(\.text), ["🔍 Review diff", "📄 Full command"])
    }

    func testSummaryBodyListsAllMCPArgs() {
        // The old body showed ONE arbitrary first-string arg — a send_message
        // card could show `text` and hide channel/workspace entirely.
        let payload = PreToolUsePayload(toolName: "mcp__Slack__send_message", toolInput: [
            "channel": AnyCodable("Jayson Rawlins"),
            "workspace": AnyCodable("defiance"),
            "limit": AnyCodable(50),
            "text": AnyCodable(String(repeating: "long message body ", count: 60)),
        ])
        let body = RemoteApprovalBridge.summaryBody(payload: payload, session: Session(pid: 1), triggerReason: nil)

        XCTAssertTrue(body.contains("channel: Jayson Rawlins"))
        XCTAssertTrue(body.contains("workspace: defiance"))
        XCTAssertTrue(body.contains("limit: 50"))
        // Long values clip per-line so they can't drown the short args.
        let textLine = body.split(separator: "\n").first { $0.hasPrefix("text: ") }
        XCTAssertNotNil(textLine)
        XCTAssertLessThan(textLine!.count, 420)
        XCTAssertTrue(textLine!.hasSuffix("…"))
    }

    func testCommandPageOffersCustomConditionRows() throws {
        let offered = server.register(command: scopableSlackContent(), resolvable: ResolvableApproval { _ in }, createScopedAllow: { _ in "rule" })
        let page = try request("/review/\(offered)")
        XCTAssertTrue(page.body.contains("customrows"))
        XCTAssertTrue(page.body.contains("condition on another arg"))

        // Non-MCP pages (no scoped section) don't offer the affordance.
        // (The page JS mentions the customrows id unconditionally, so assert
        // on the button markup, which only the scoped section renders.)
        let plain = server.register(command: makeCommand(), resolvable: ResolvableApproval { _ in })
        let plainPage = try request("/review/\(plain)")
        XCTAssertFalse(plainPage.body.contains("condition on another arg"))
        XCTAssertFalse(plainPage.body.contains("<div id=\"customrows\">"))
    }

    func testSummaryBodyTruncationPointsAtLink() {
        let long = String(repeating: "x", count: GavelConstants.telegramBodyMaxChars + 100)
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable(long)])
        let session = Session(pid: 1)

        let linked = RemoteApprovalBridge.summaryBody(payload: payload, session: session, triggerReason: nil, hasCommandLink: true)
        XCTAssertTrue(linked.contains("full at the link"))

        let unlinked = RemoteApprovalBridge.summaryBody(payload: payload, session: session, triggerReason: nil)
        XCTAssertTrue(unlinked.contains("full on Mac"))
    }

    // MARK: - Proposal adjudication from Telegram

    private func makeStores() -> (ProposalStore, RuleStore) {
        let dir = NSTemporaryDirectory() + "gavel-cmdreview-test-\(UUID().uuidString)"
        let ruleStore = RuleStore(configPath: dir + "/rules.json")
        let proposals = ProposalStore(path: dir + "/proposals.json")
        proposals.ruleStore = ruleStore
        return (proposals, ruleStore)
    }

    private func submitProposal(_ store: ProposalStore) -> UUID {
        let result = store.submit(
            toolName: "Bash", pattern: "rm\\s+-rf\\s+/", isRegex: true, verdict: "deny",
            reason: "Catastrophic delete pattern seen in session", example: "rm -rf / --no-preserve-root",
            sessionPid: 111, sessionId: nil)
        guard case .queued(let id) = result else {
            XCTFail("proposal not queued: \(result)")
            return UUID()
        }
        return id
    }

    private func proposalCallback(action: String, id: UUID, messageId: Int = 100) -> TelegramUpdate {
        TelegramUpdate(
            updateId: 1,
            callback: TelegramCallback(id: "cb1", fromId: owner, chatId: owner, messageId: messageId, data: "\(action):\(id.uuidString)"),
            message: nil)
    }

    func testProposalNotifySendsCardWithAdjudicationButtons() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let (proposals, _) = makeStores()
        bridge.proposalStore = proposals
        let id = submitProposal(proposals)
        let proposal = try XCTUnwrap(proposals.proposals.first { $0.id == id })

        bridge.notifyProposal(proposal)

        let sent = try XCTUnwrap(fake.sentMessages.last)
        XCTAssertTrue(sent.text.contains("Claude proposed a rule"))
        XCTAssertTrue(sent.text.contains("rm\\s+-rf\\s+/"))
        XCTAssertTrue(sent.text.contains("DENY"))
        let callbacks = (sent.keyboard ?? []).flatMap { $0 }.compactMap(\.callbackData)
        XCTAssertTrue(callbacks.contains("pa:\(id.uuidString)"))
        XCTAssertTrue(callbacks.contains("pj:\(id.uuidString)"))
    }

    func testProposalAcceptFromPhoneCreatesRule() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let (proposals, ruleStore) = makeStores()
        bridge.proposalStore = proposals
        let id = submitProposal(proposals)

        bridge.handle(proposalCallback(action: "pa", id: id))
        drainMain()

        XCTAssertTrue(ruleStore.rules.contains { $0.pattern == "rm\\s+-rf\\s+/" && $0.verdict == .block })
        XCTAssertTrue(proposals.proposals.isEmpty)
        XCTAssertEqual(fake.edits.last?.text.contains("Rule accepted from phone"), true)
    }

    func testProposalRejectFromPhoneDropsWithoutRule() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let (proposals, ruleStore) = makeStores()
        bridge.proposalStore = proposals
        let id = submitProposal(proposals)

        bridge.handle(proposalCallback(action: "pj", id: id))
        drainMain()

        XCTAssertFalse(ruleStore.rules.contains { $0.pattern == "rm\\s+-rf\\s+/" })
        XCTAssertTrue(proposals.proposals.isEmpty)
        XCTAssertEqual(fake.edits.last?.text.contains("rejected from phone"), true)
    }

    func testProposalTapAfterMonitorAdjudicationIsNoOp() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let (proposals, ruleStore) = makeStores()
        bridge.proposalStore = proposals
        let id = submitProposal(proposals)

        proposals.reject(id: id, via: "monitor")
        let rulesBefore = ruleStore.rules.count
        bridge.handle(proposalCallback(action: "pa", id: id))
        drainMain()

        XCTAssertEqual(ruleStore.rules.count, rulesBefore)
        XCTAssertEqual(fake.answers.last?.text, "Already handled")
    }

    func testProposalCallbackFromWrongChatIgnored() throws {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let (proposals, ruleStore) = makeStores()
        bridge.proposalStore = proposals
        let id = submitProposal(proposals)

        let stranger = TelegramUpdate(
            updateId: 1,
            callback: TelegramCallback(id: "cb2", fromId: 666, chatId: 666, messageId: 5, data: "pa:\(id.uuidString)"),
            message: nil)
        bridge.handle(stranger)
        drainMain()

        XCTAssertFalse(ruleStore.rules.contains { $0.pattern == "rm\\s+-rf\\s+/" })
        XCTAssertEqual(proposals.proposals.count, 1)
        XCTAssertEqual(fake.answers.last?.text, "Not authorized")
    }

    // MARK: - Scoped Always Allow from the command page

    private func scopableSlackContent() -> CommandContent {
        makeCommand(command: nil, args: [
            CommandArg(name: "channel", value: "general", scopable: true),
            CommandArg(name: "limit", value: "50", scopable: true),
            CommandArg(name: "filters", value: "{\"a\":1}", scopable: false),
        ], offersScopedAllow: true)
    }

    func testScopeSectionRenderedOnlyWhenOffered() throws {
        let offered = server.register(command: scopableSlackContent(), resolvable: ResolvableApproval { _ in }, createScopedAllow: { _ in "rule" })
        let offeredPage = try request("/review/\(offered)")
        XCTAssertTrue(offeredPage.body.contains("Always allow, scoped to"))
        // Scopable args get rows; non-scalar args don't.
        XCTAssertTrue(offeredPage.body.contains("pat-channel"))
        XCTAssertTrue(offeredPage.body.contains("pat-limit"))
        XCTAssertFalse(offeredPage.body.contains("pat-filters"))

        let plain = server.register(command: makeCommand(), resolvable: ResolvableApproval { _ in })
        let plainPage = try request("/review/\(plain)")
        XCTAssertFalse(plainPage.body.contains("Always allow, scoped to"))
    }

    func testScopeRowPrefillsEscapedRegex() throws {
        let content = makeCommand(command: nil, args: [
            CommandArg(name: "query", value: "a.b+c", scopable: true),
        ], offersScopedAllow: true)
        let nonce = server.register(command: content, resolvable: ResolvableApproval { _ in }, createScopedAllow: { _ in "rule" })
        let page = try request("/review/\(nonce)")
        // Literal value must arrive regex-escaped so "a.b+c" can't match "axbbc".
        XCTAssertTrue(page.body.contains("a\\.b\\+c"))
    }

    func testAllowScopedCreatesRuleAndResolvesAllow() throws {
        var decision: Decision?
        var received: [String: String]?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { conditions in
                received = conditions
                return "mcp__Slack__read_history: * [channel=/general/]"
            })

        let body = #"{"verdict":"allow_scoped","note":"watcher scope","conditions":{"channel":"general","workspace":"defiance"}}"#
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
        XCTAssertEqual(res.status, 200)

        XCTAssertEqual(received, ["channel": "general", "workspace": "defiance"])
        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .allow)
        XCTAssertEqual(d.reason?.contains("always allow: mcp__Slack__read_history"), true)
        XCTAssertEqual(d.additionalContext?.contains("watcher scope"), true)
    }

    func testAllowScopedWithoutCallbackIs400() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(command: makeCommand(), resolvable: resolvable)

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow_scoped","conditions":{"channel":"x"}}"#)
        XCTAssertEqual(res.status, 400)
        XCTAssertNil(decision)
        XCTAssertFalse(resolvable.isResolved)
    }

    func testAllowScopedWithEmptyConditionsIs400() throws {
        var created = false
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { _ in created = true; return "rule" })

        for body in [#"{"verdict":"allow_scoped"}"#,
                     #"{"verdict":"allow_scoped","conditions":{}}"#,
                     #"{"verdict":"allow_scoped","conditions":{" ":"x","channel":"  "}}"#] {
            let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
            XCTAssertEqual(res.status, 400, "body: \(body)")
        }
        XCTAssertFalse(created)
        XCTAssertFalse(resolvable.isResolved)
    }

    func testAllowScopedWithInvalidRegexIs400() throws {
        var created = false
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { _ in created = true; return "rule" })

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow_scoped","conditions":{"channel":"gen("}}"#)
        XCTAssertEqual(res.status, 400)
        XCTAssertFalse(created)
    }

    func testAllowScopedOnResolvedApprovalIs409WithoutRule() throws {
        var created = false
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { _ in created = true; return "rule" })

        _ = resolvable.resolve(Decision(verdict: .allow, reason: "Mac won"), from: .mac)
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow_scoped","conditions":{"channel":"general"}}"#)
        XCTAssertEqual(res.status, 409)
        XCTAssertFalse(created, "stale submissions must not author rules")
    }

    // MARK: - Session-scoped allow from the command page

    func testAllowSessionScopedCreatesSessionRuleAndResolves() throws {
        var decision: Decision?
        var received: [String: String]?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedSessionAllow: { conditions in
                received = conditions
                return "mcp__Slack__read_history [channel=/general/]"
            })

        let body = #"{"verdict":"allow_session_scoped","conditions":{"channel":"general"}}"#
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
        XCTAssertEqual(res.status, 200)

        XCTAssertEqual(received, ["channel": "general"])
        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .allow)
        XCTAssertEqual(d.reason?.contains("session allow (scoped)"), true)
    }

    func testAllowSessionScopedWithoutCallbackIs400() throws {
        // A page with only the persistent callback still 400s the session verb.
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { _ in "rule" })

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"allow_session_scoped","conditions":{"channel":"x"}}"#)
        XCTAssertEqual(res.status, 400)
        XCTAssertFalse(resolvable.isResolved)
    }

    func testSessionRuleArgConditionsScopeMatching() {
        let session = Session(pid: 1)
        session.sessionRules.append(SessionRule(
            toolName: "mcp__Slack__read_history", pattern: "*",
            verdict: .allow, argConditions: ["channel": "general", "workspace": "defiance"]))

        func input(channel: String, workspace: String = "defiance") -> [String: AnyCodable] {
            ["channel": AnyCodable(channel), "workspace": AnyCodable(workspace)]
        }
        XCTAssertNotNil(session.matchesSessionRule(
            toolName: "mcp__Slack__read_history", command: nil, filePath: nil,
            toolInput: input(channel: "general")))
        // Out-of-scope channel, wrong workspace, and absent args all fall through.
        XCTAssertNil(session.matchesSessionRule(
            toolName: "mcp__Slack__read_history", command: nil, filePath: nil,
            toolInput: input(channel: "random")))
        XCTAssertNil(session.matchesSessionRule(
            toolName: "mcp__Slack__read_history", command: nil, filePath: nil,
            toolInput: input(channel: "general", workspace: "macedon")))
        XCTAssertNil(session.matchesSessionRule(
            toolName: "mcp__Slack__read_history", command: nil, filePath: nil,
            toolInput: ["channel": AnyCodable("general")]))
        XCTAssertNil(session.matchesSessionRule(
            toolName: "mcp__Slack__read_history", command: nil, filePath: nil))
    }

    func testSessionRuleAnchoringAndDenyStripMatchPersistentSemantics() {
        // Anchoring: "C123" must not substring-match "C1234".
        let anchored = SessionRule(
            toolName: "mcp__T__t", pattern: "*", verdict: .allow, argConditions: ["c": "C123"])
        XCTAssertTrue(anchored.matches(toolName: "mcp__T__t", command: nil, filePath: nil, toolInput: ["c": AnyCodable("C123")]))
        XCTAssertFalse(anchored.matches(toolName: "mcp__T__t", command: nil, filePath: nil, toolInput: ["c": AnyCodable("C1234")]))

        // Conditions on a session DENY would narrow it — init drops them.
        let deny = SessionRule(
            toolName: "mcp__T__t", pattern: "*", verdict: .block, argConditions: ["c": "C123"])
        XCTAssertNil(deny.argConditions)
        XCTAssertTrue(deny.matches(toolName: "mcp__T__t", command: nil, filePath: nil, toolInput: ["c": AnyCodable("other")]))

        // Backward compat: nil conditions ignore toolInput entirely.
        let plain = SessionRule(toolName: "mcp__T__t", pattern: "*")
        XCTAssertTrue(plain.matches(toolName: "mcp__T__t", command: nil, filePath: nil, toolInput: ["c": AnyCodable("anything")]))
    }

    /// End-to-end: the rule authored from the page actually scopes future
    /// matching — in-scope calls allow, out-of-scope calls fall through.
    func testScopedRuleFromPageScopesFutureEvaluation() throws {
        let dir = NSTemporaryDirectory() + "gavel-scopedpage-test-\(UUID().uuidString)"
        let ruleStore = RuleStore(configPath: dir + "/rules.json")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        // Mirrors the coordinator's closure: exact tool name, glob "*",
        // conditions from the page (rule added synchronously here; the
        // coordinator hops to main for the live store).
        let nonce = server.register(
            command: scopableSlackContent(), resolvable: resolvable,
            createScopedAllow: { conditions in
                let rule = PersistentRule(
                    toolName: "mcp__Slack__read_history", pattern: "*", isRegex: false,
                    verdict: .allow, argConditions: conditions)
                ruleStore.addRule(rule, origin: "test")
                return rule.name
            })

        let body = #"{"verdict":"allow_scoped","conditions":{"channel":"general","workspace":"defiance"}}"#
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(decision?.verdict, .allow)

        func payload(channel: String, workspace: String = "defiance") -> PreToolUsePayload {
            PreToolUsePayload(toolName: "mcp__Slack__read_history", toolInput: [
                "channel": AnyCodable(channel), "workspace": AnyCodable(workspace), "limit": AnyCodable(50),
            ])
        }
        XCTAssertNotNil(ruleStore.evaluateAllow(payload: payload(channel: "general")))
        XCTAssertNil(ruleStore.evaluateAllow(payload: payload(channel: "random")))
        XCTAssertNil(ruleStore.evaluateAllow(payload: payload(channel: "general", workspace: "macedon")))
    }
}
