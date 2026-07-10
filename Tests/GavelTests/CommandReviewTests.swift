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
        args: [(name: String, value: String)] = [],
        withheldInline: Bool = false
    ) -> CommandContent {
        CommandContent(
            sessionLabel: "argscope",
            toolName: command != nil ? "Bash" : "mcp__Slack__read_history",
            cwd: "/Users/x/code/project",
            command: command,
            args: args,
            triggerReason: "Default rule: something fired",
            withheldInline: withheldInline)
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
            (name: "channel", value: "general"),
            (name: "workspace", value: "defiance"),
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

        XCTAssertFalse(ruleStore.rules.contains { $0.pattern == "rm\\s+-rf\\s+/" })
        XCTAssertEqual(proposals.proposals.count, 1)
        XCTAssertEqual(fake.answers.last?.text, "Not authorized")
    }
}
