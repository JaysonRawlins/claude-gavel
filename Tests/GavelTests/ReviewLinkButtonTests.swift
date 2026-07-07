import XCTest

@testable import Gavel

final class ReviewLinkButtonTests: XCTestCase {

    private let owner: Int64 = 42

    func testReviewURLLeadsKeyboardAsURLButton() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(
            resolvable: approval, text: "commit?", allowSession: nil,
            offerCommentClean: true,
            reviewURL: "https://mac.tail1234.ts.net:8443/review/abc123")

        let keyboard = try! XCTUnwrap(fake.sentMessages.last?.keyboard)
        let first = try! XCTUnwrap(keyboard.first?.first)
        XCTAssertEqual(first.text, "🔍 Review diff")
        XCTAssertEqual(first.url, "https://mac.tail1234.ts.net:8443/review/abc123")
        XCTAssertNil(first.callbackData)

        // Verdict buttons still present and callback-typed.
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("a:") })
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("d:") })
        XCTAssertTrue(fake.lastCallbackData.contains { $0.hasPrefix("c:") })
    }

    func testWebResolutionEditsMessageWithReviewLabel() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(
            resolvable: approval, text: "commit?", allowSession: nil,
            reviewURL: "https://mac.ts.net:8443/review/abc")
        approval.resolve(Decision(verdict: .allow, reason: "User approved via web review"), from: .web)

        XCTAssertTrue(fake.edits.contains { $0.text.contains("review page") },
                      "web resolution must not read as 'Answered on Mac'")
    }

    func testNoReviewURLMeansNoURLButtons() {
        let fake = FakeTelegramTransport()
        let bridge = RemoteApprovalBridge(transport: fake, chatId: owner)
        let approval = ResolvableApproval { _ in }

        bridge.notify(resolvable: approval, text: "cmd?", allowSession: nil)

        let keyboard = fake.sentMessages.last?.keyboard ?? []
        XCTAssertTrue(keyboard.flatMap { $0 }.allSatisfy { $0.url == nil })
    }
}
