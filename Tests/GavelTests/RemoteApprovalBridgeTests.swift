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

        let start = TelegramUpdate(updateId: 1, callback: nil, message: TelegramIncomingMessage(fromId: owner, chatId: owner, text: "/start"))
        bridge.handle(start)

        XCTAssertEqual(pairedWith, owner)
        XCTAssertTrue(bridge.isPaired)
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
}
