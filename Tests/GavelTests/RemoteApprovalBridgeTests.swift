import XCTest
@testable import Gavel

final class RemoteApprovalBridgeTests: XCTestCase {

    private let owner: Int64 = 42

    private func nonce(from data: [String]) -> String {
        let allow = data.first { $0.hasPrefix("a:") } ?? ""
        return String(allow.dropFirst(2))
    }

    private func callbackUpdate(action: String, nonce: String, fromId: Int64, chatId: Int64, messageId: Int) -> TelegramUpdate {
        TelegramUpdate(
            updateId: 1,
            callback: TelegramCallback(id: "cb1", fromId: fromId, chatId: chatId, messageId: messageId, data: "\(action):\(nonce)"),
            message: nil
        )
    }

    func testTelegramAllowResolvesAndEdits() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        XCTAssertEqual(fake.sentMessages.count, 1)

        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "a", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertEqual(resolved?.verdict, .allow)
        XCTAssertEqual(fake.answers.last?.text, "Allowed")
        XCTAssertTrue(fake.edits.contains { $0.text.contains("from phone") })
    }

    func testAllowSiteButtonGrantsLeaseAndResolvesAllow() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        var leaseGranted = false
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(
            resolvable: approval, text: "navigate?", allowSession: nil,
            leaseDomain: "example.com", allowSite: { leaseGranted = true })
        XCTAssertTrue(
            fake.lastCallbackData.contains { $0.hasPrefix("g:") },
            "keyboard should carry the Allow-site button")

        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "g", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertTrue(leaseGranted)
        XCTAssertEqual(resolved?.verdict, .allow)
        XCTAssertEqual(resolved?.reason, "Browsing lease granted from phone")
        XCTAssertTrue(fake.edits.contains { $0.text.contains("Site leased from phone") })
    }

    func testNoAllowSiteButtonWithoutLeaseDomain() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)

        bridge.notify(resolvable: ResolvableApproval { _ in }, text: "approve?", allowSession: nil)
        XCTAssertFalse(fake.lastCallbackData.contains { $0.hasPrefix("g:") })
    }

    func testUnauthorizedChatIgnored() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "a", nonce: n, fromId: 999, chatId: 999, messageId: fake.lastSentMessageId))

        XCTAssertNil(resolved)
        XCTAssertEqual(fake.answers.last?.text, "Not authorized")
    }

    func testStaleNonceIsNoOp() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)

        bridge.handle(callbackUpdate(action: "a", nonce: "deadbeef", fromId: owner, chatId: owner, messageId: 1))

        XCTAssertEqual(fake.answers.last?.text, "Already resolved")
    }

    func testMacWinsThenLateTelegramTapIsNoOp() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)

        approval.resolve(Decision(verdict: .block, reason: "denied on mac"), from: .mac)
        XCTAssertTrue(fake.edits.contains { $0.text.contains("Answered on Mac") })

        bridge.handle(callbackUpdate(action: "a", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))
        XCTAssertEqual(resolved?.verdict, .block)
        XCTAssertEqual(fake.answers.last?.text, "Already resolved")
    }

    func testPairingCapturesChatIdFromStart() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: nil)
        var pairedWith: Int64?
        bridge.onPaired = { pairedWith = $0 }

        let start = TelegramUpdate(updateId: 1, callback: nil, message: TelegramIncomingMessage(fromId: owner, chatId: owner, text: "/start", replyToMessageId: nil))
        bridge.handle(start)

        XCTAssertEqual(pairedWith, owner)
        XCTAssertTrue(bridge.isPaired)
    }

    func testTypedReplyDeniesWithInstruction() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        let reply = TelegramUpdate(updateId: 2, callback: nil, message: TelegramIncomingMessage(fromId: owner, chatId: owner, text: "clean it up first", replyToMessageId: nil))
        bridge.handle(reply)

        XCTAssertEqual(resolved?.verdict, .block)
        XCTAssertEqual(resolved?.reason, "Denied from phone — clean it up first")
    }

    func testTypedReplyFromWrongChatIgnored() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        let reply = TelegramUpdate(updateId: 2, callback: nil, message: TelegramIncomingMessage(fromId: 999, chatId: 999, text: "do it", replyToMessageId: nil))
        bridge.handle(reply)

        XCTAssertNil(resolved)
    }

    func testCleanButtonDeniesWithCommentInstruction() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "commit?", allowSession: nil, offerCommentClean: true)
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("c:") })
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "c", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertEqual(resolved?.verdict, .block)
        XCTAssertEqual(resolved?.reason?.contains("comment"), true)
    }

    func testCleanButtonAbsentByDefault() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        bridge.notify(resolvable: ResolvableApproval { _ in }, text: "x", allowSession: nil)
        XCTAssertFalse(fake.lastCallbackData.contains { $0.hasPrefix("c:") })
    }

    private func typedReply(_ text: String, replyTo: Int? = nil) -> TelegramUpdate {
        TelegramUpdate(updateId: 9, callback: nil, message: TelegramIncomingMessage(fromId: owner, chatId: owner, text: text, replyToMessageId: replyTo))
    }

    func testBareTypedReplyResolvesWhenOnePending() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        bridge.notify(resolvable: ResolvableApproval { resolved = $0 }, text: "a", allowSession: nil)
        bridge.handle(typedReply("clean it"))
        XCTAssertEqual(resolved?.verdict, .block)
        XCTAssertEqual(resolved?.reason, "Denied from phone — clean it")
    }

    func testBareTypedReplyIsAmbiguousWithMultiplePending() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var r1: Decision?
        var r2: Decision?
        bridge.notify(resolvable: ResolvableApproval { r1 = $0 }, text: "a1", allowSession: nil)
        bridge.notify(resolvable: ResolvableApproval { r2 = $0 }, text: "a2", allowSession: nil)
        bridge.handle(typedReply("do it"))
        XCTAssertNil(r1)
        XCTAssertNil(r2)
        XCTAssertEqual(fake.sentMessages.last?.text.contains("pending") == true, true)
    }

    func testReplyToTargetsSpecificApprovalWhenMultiplePending() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var r1: Decision?
        var r2: Decision?
        bridge.notify(resolvable: ResolvableApproval { r1 = $0 }, text: "a1", allowSession: nil)
        let firstMessageId = fake.lastSentMessageId
        bridge.notify(resolvable: ResolvableApproval { r2 = $0 }, text: "a2", allowSession: nil)
        bridge.handle(typedReply("no", replyTo: firstMessageId))
        XCTAssertEqual(r1?.verdict, .block)
        XCTAssertNil(r2)
    }

    func testBurstCoalescesAfterTokenBucketDrains() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        for i in 0..<8 {
            bridge.notify(resolvable: ResolvableApproval { _ in }, text: "a\(i)", allowSession: nil)
        }
        let buttonMessages = fake.sentMessages.filter { $0.keyboard != nil }.count
        let coalesceNotices = fake.sentMessages.filter { $0.keyboard == nil && $0.text.contains("too fast") }.count
        XCTAssertEqual(buttonMessages, 5)
        XCTAssertGreaterThanOrEqual(coalesceNotices, 1)
    }

    func testAllowForSessionInvokesCallback() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }
        var sessionAllowed = false

        bridge.notify(resolvable: approval, text: "approve?", allowSession: { sessionAllowed = true })
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "s", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertTrue(sessionAllowed)
    }

    func testSummaryBodyRedactsAndOmitsFileContent() {
        let session = Session(pid: 123)
        session.label = "demo"
        let payload = PreToolUsePayload(
            toolName: "Write",
            toolInput: [
                "file_path": AnyCodable("/tmp/out.txt"),
                "content": AnyCodable("super secret body AKIAIOSFODNN7EXAMPLE that should never ship")
            ]
        )
        let body = RemoteApprovalBridge.summaryBody(payload: payload, session: session, triggerReason: nil)

        XCTAssertTrue(body.contains("/tmp/out.txt"))
        XCTAssertFalse(body.contains("super secret body"))
        XCTAssertFalse(body.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    func testWithheldBodyCarriesMetadataButNoCommand() {
        let session = Session(pid: 123, cwd: "/Users/jay/code/claude-gavel")
        session.label = "demo"
        let payload = PreToolUsePayload(
            toolName: "Bash",
            toolInput: ["command": AnyCodable("aws configure set aws_secret_access_key AKIAIOSFODNN7EXAMPLE")]
        )
        let body = RemoteApprovalBridge.withheldBody(payload: payload, session: session)

        XCTAssertTrue(body.contains("demo"))
        XCTAssertTrue(body.contains("Bash"))
        XCTAssertTrue(body.contains("claude-gavel"))
        XCTAssertFalse(body.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(body.contains("aws configure"))
    }

    func testRemoteLogTrailCapturesSendAndResolve() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var logs: [String] = []
        bridge.remoteLog = { logs.append($0) }
        let approval = ResolvableApproval { _ in }

        bridge.notify(resolvable: approval, text: "approve?", pid: 4242, toolName: "Bash", withheld: true, allowSession: nil)
        XCTAssertTrue(logs.contains { $0.hasPrefix("sent pid=4242") && $0.contains("tool=Bash") && $0.contains("withheld=true") })

        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "d", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))
        XCTAssertTrue(logs.contains { $0.hasPrefix("resolved pid=4242") && $0.contains("action=d") && $0.contains("won=true") })
    }

    func testRemoteLogRecordsFloodCoalesce() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var logs: [String] = []
        bridge.remoteLog = { logs.append($0) }

        for i in 0..<7 {
            bridge.notify(resolvable: ResolvableApproval { _ in }, text: "x", pid: i, toolName: "Bash", allowSession: nil)
        }
        XCTAssertTrue(logs.contains { $0.hasPrefix("coalesced") })
    }

    func testDenyWithReasonButtonOffered() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        bridge.notify(resolvable: ResolvableApproval { _ in }, text: "approve?", allowSession: nil)
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("dr:") })
    }

    func testDenyWithReasonButtonIssuesForceReplyWithoutResolving() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", toolName: "Bash", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "dr", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertNil(resolved)
        XCTAssertEqual(fake.forceReplies.count, 1)
        XCTAssertTrue(fake.forceReplies.last?.text.contains("Bash") == true)
        XCTAssertEqual(fake.answers.last?.text, "Reply with a reason")
    }

    func testReplyToForceReplyPromptDeniesCorrectApproval() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var r1: Decision?
        var r2: Decision?
        bridge.notify(resolvable: ResolvableApproval { r1 = $0 }, text: "a1", allowSession: nil)
        let firstNonce = nonce(from: fake.lastCallbackData)
        bridge.notify(resolvable: ResolvableApproval { r2 = $0 }, text: "a2", allowSession: nil)

        bridge.handle(callbackUpdate(action: "dr", nonce: firstNonce, fromId: owner, chatId: owner, messageId: 100))
        let promptMid = fake.forceReplies.last!.messageId
        bridge.handle(typedReply("looks unsafe", replyTo: promptMid))

        XCTAssertEqual(r1?.verdict, .block)
        XCTAssertEqual(r1?.reason, "Denied from phone — looks unsafe")
        XCTAssertNil(r2)
    }

    func testReplyToForceReplyPromptAfterResolutionIsNoOp() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolveCount = 0
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0; resolveCount += 1 }

        bridge.notify(resolvable: approval, text: "approve?", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "dr", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))
        let promptMid = fake.forceReplies.last!.messageId

        approval.resolve(Decision(verdict: .block, reason: "denied on mac"), from: .mac)
        bridge.handle(typedReply("too late", replyTo: promptMid))

        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(resolved?.reason, "denied on mac")
    }

    func testAllowWithNoteButtonOffered() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        bridge.notify(resolvable: ResolvableApproval { _ in }, text: "approve?", allowSession: nil)
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("ar:") })
    }

    func testAllowWithNoteButtonIssuesForceReplyWithoutResolving() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "approve?", toolName: "Bash", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "ar", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertNil(resolved)
        XCTAssertEqual(fake.forceReplies.count, 1)
        XCTAssertTrue(fake.forceReplies.last?.text.contains("Bash") == true)
        XCTAssertEqual(fake.answers.last?.text, "Reply with a note")
    }

    func testReplyToAllowNotePromptApprovesWithContext() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        bridge.notify(resolvable: ResolvableApproval { resolved = $0 }, text: "approve?", toolName: "Bash", allowSession: nil)
        let n = nonce(from: fake.lastCallbackData)

        bridge.handle(callbackUpdate(action: "ar", nonce: n, fromId: owner, chatId: owner, messageId: 100))
        let promptMid = fake.forceReplies.last!.messageId
        bridge.handle(typedReply("ship it, ran the migration", replyTo: promptMid))

        XCTAssertEqual(resolved?.verdict, .allow)
        XCTAssertEqual(resolved?.additionalContext, "Approver note from phone: ship it, ran the migration")
    }

    func testReplyToAllowNotePromptTargetsCorrectApprovalWhenMultiplePending() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var r1: Decision?
        var r2: Decision?
        bridge.notify(resolvable: ResolvableApproval { r1 = $0 }, text: "a1", allowSession: nil)
        let firstNonce = nonce(from: fake.lastCallbackData)
        bridge.notify(resolvable: ResolvableApproval { r2 = $0 }, text: "a2", allowSession: nil)

        bridge.handle(callbackUpdate(action: "ar", nonce: firstNonce, fromId: owner, chatId: owner, messageId: 100))
        let promptMid = fake.forceReplies.last!.messageId
        bridge.handle(typedReply("approved", replyTo: promptMid))

        XCTAssertEqual(r1?.verdict, .allow)
        XCTAssertNil(r2)
    }

    func testWithheldApprovalIsResolvableFromPhoneWithButtons() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var resolved: Decision?
        let approval = ResolvableApproval { resolved = $0 }

        bridge.notify(resolvable: approval, text: "🔒 Gavel — command withheld", allowSession: nil)
        XCTAssertFalse(fake.lastCallbackData.isEmpty)

        let n = nonce(from: fake.lastCallbackData)
        bridge.handle(callbackUpdate(action: "d", nonce: n, fromId: owner, chatId: owner, messageId: fake.lastSentMessageId))

        XCTAssertEqual(resolved?.verdict, .block)
    }

    func testStopPhoneMessageFiresCallback() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var stopped = false
        bridge.onStopPhone = { stopped = true }

        bridge.handle(typedReply("[[/stop-phone]]"))

        XCTAssertTrue(stopped)
    }

    func testStopPhoneFromWrongChatIgnored() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        var stopped = false
        bridge.onStopPhone = { stopped = true }

        let foreign = TelegramUpdate(updateId: 9, callback: nil, message: TelegramIncomingMessage(fromId: 999, chatId: 999, text: "[[/stop-phone]]", replyToMessageId: nil))
        bridge.handle(foreign)

        XCTAssertFalse(stopped)
    }

    func testSendNoticePostsToPinnedChat() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        bridge.sendNotice("Phone off")
        XCTAssertEqual(fake.sentMessages.last?.chatId, owner)
        XCTAssertEqual(fake.sentMessages.last?.text, "Phone off")
    }
}
