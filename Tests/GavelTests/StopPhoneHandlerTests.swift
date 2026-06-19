import XCTest
@testable import Gavel

final class StopPhoneHandlerTests: XCTestCase {

    private func isolatedManager() -> SessionManager {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-stopphone-tests-\(UUID().uuidString)")
        return SessionManager(homeDir: tmp, autoStartTimers: false, autoDiscover: false)
    }

    private func event(_ line: String, type: String = "user") -> JsonlEvent {
        JsonlEvent(rawLine: line, json: ["type": type], sessionId: "s", cwd: "/tmp")
    }

    func testMatchesMarker() {
        XCTAssertTrue(StopPhoneHandler.matches("please [[/stop-phone]] now"))
    }

    func testMatchesCaseInsensitive() {
        XCTAssertTrue(StopPhoneHandler.matches("[[/STOP-PHONE]]"))
    }

    func testIgnoresPlainText() {
        XCTAssertFalse(StopPhoneHandler.matches("stop the phone please"))
        XCTAssertFalse(StopPhoneHandler.matches("[[/stop]]"))
    }

    func testUserEntryDisablesPhoneEverywhere() {
        let handler = StopPhoneHandler()
        let manager = isolatedManager()
        manager.telegramChatId = 7
        manager.defaultRemoteApprove = true
        let session = manager.session(for: 91001)
        session.setRemoteApprovalEnabled(true, until: nil)

        let stopped = expectation(description: "phone stopped")
        manager.onPhoneStopped = { affected in
            XCTAssertEqual(affected, 1)
            stopped.fulfill()
        }
        handler.handle(event("[[/stop-phone]]"), manager: manager, session: session)
        wait(for: [stopped], timeout: 2)

        XCTAssertFalse(session.remoteApprovalSnapshot.enabled)
        XCTAssertFalse(manager.defaultRemoteApprove)
    }

    func testNonUserEntryIgnored() {
        let handler = StopPhoneHandler()
        let manager = isolatedManager()
        manager.defaultRemoteApprove = true

        let notStopped = expectation(description: "callback not fired")
        notStopped.isInverted = true
        manager.onPhoneStopped = { _ in notStopped.fulfill() }
        handler.handle(event("[[/stop-phone]]", type: "assistant"), manager: manager, session: manager.session(for: 91002))
        wait(for: [notStopped], timeout: 0.5)

        XCTAssertTrue(manager.defaultRemoteApprove)
    }
}
