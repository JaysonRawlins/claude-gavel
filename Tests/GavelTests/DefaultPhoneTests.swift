import XCTest
@testable import Gavel

final class DefaultPhoneTests: XCTestCase {

    private func homeDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-defaultphone-tests-\(UUID().uuidString)")
    }

    private func manager(_ home: URL) -> SessionManager {
        SessionManager(homeDir: home, autoStartTimers: false, autoDiscover: false)
    }

    func testNewSessionInheritsPhoneWhenPaired() {
        let m = manager(homeDir())
        m.telegramChatId = 7
        m.defaultRemoteApprove = true
        let session = m.session(for: 92001)
        XCTAssertTrue(session.isRemoteApprovalActive)
        XCTAssertNil(session.remoteApprovalSnapshot.until)
    }

    func testNewSessionDoesNotInheritPhoneWhenUnpaired() {
        let m = manager(homeDir())
        m.telegramChatId = nil
        m.defaultRemoteApprove = true
        let session = m.session(for: 92002)
        XCTAssertFalse(session.isRemoteApprovalActive)
    }

    func testNewSessionNoPhoneWhenDefaultOff() {
        let m = manager(homeDir())
        m.telegramChatId = 7
        m.defaultRemoteApprove = false
        let session = m.session(for: 92003)
        XCTAssertFalse(session.isRemoteApprovalActive)
    }

    func testDefaultRemoteApproveRoundTrips() {
        let home = homeDir()
        let first = manager(home)
        first.defaultRemoteApprove = true
        first.saveDefaults()

        let second = manager(home)
        XCTAssertTrue(second.defaultRemoteApprove)
    }

    func testStopAllPhoneClearsSessionsAndDefault() {
        let m = manager(homeDir())
        m.telegramChatId = 7
        m.defaultRemoteApprove = true
        let a = m.session(for: 92010)
        let b = m.session(for: 92011)

        let stopped = expectation(description: "stopped")
        m.onPhoneStopped = { affected in
            XCTAssertEqual(affected, 2)
            stopped.fulfill()
        }
        m.stopAllPhone()
        wait(for: [stopped], timeout: 2)

        XCTAssertFalse(a.remoteApprovalSnapshot.enabled)
        XCTAssertFalse(b.remoteApprovalSnapshot.enabled)
        XCTAssertFalse(m.defaultRemoteApprove)
    }
}
