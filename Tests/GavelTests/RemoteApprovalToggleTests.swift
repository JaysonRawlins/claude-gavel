import XCTest
@testable import Gavel

final class RemoteApprovalToggleTests: XCTestCase {

    func testForceRemoteMirrorSendsEvenWhenSessionPhoneOff() {
        XCTAssertTrue(ApprovalCoordinator.shouldMirrorRemote(forceRemoteMirror: true, sessionActive: false))
    }

    func testNoMirrorWhenNeitherForcedNorActive() {
        XCTAssertFalse(ApprovalCoordinator.shouldMirrorRemote(forceRemoteMirror: false, sessionActive: false))
    }

    func testMirrorWhenSessionActive() {
        XCTAssertTrue(ApprovalCoordinator.shouldMirrorRemote(forceRemoteMirror: false, sessionActive: true))
    }

    func testSessionStartDecodesRemoteApprovalRequest() throws {
        let json = """
        {
            "hookType": "SessionStart",
            "sessionPid": 4242,
            "timestamp": 1712600000.0,
            "payload": {
                "type": "SessionStart",
                "session_id": "sess-1",
                "source": "startup",
                "request_remote_approval": true
            }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .sessionStart(let payload) = event.payload else {
            XCTFail("Expected sessionStart payload")
            return
        }
        XCTAssertEqual(payload.requestRemoteApproval, true)
    }

    func testSessionStartAbsentFlagDecodesNil() throws {
        let json = """
        {
            "hookType": "SessionStart",
            "sessionPid": 4242,
            "timestamp": 1712600000.0,
            "payload": { "type": "SessionStart", "source": "startup" }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        guard case .sessionStart(let payload) = event.payload else {
            XCTFail("Expected sessionStart payload")
            return
        }
        XCTAssertNil(payload.requestRemoteApproval)
    }

    func testEnableGrantActiveWithFutureExpiry() {
        let session = Session(pid: 4242)
        session.setRemoteApprovalEnabled(true, until: Date().addingTimeInterval(3600))
        XCTAssertTrue(session.isRemoteApprovalActive)
    }

    func testExpiredGrantIsInactiveFailClosed() {
        let session = Session(pid: 4242)
        session.setRemoteApprovalEnabled(true, until: Date().addingTimeInterval(-1))
        XCTAssertFalse(session.isRemoteApprovalActive)
    }

    func testDisableDeactivates() {
        let session = Session(pid: 4242)
        session.setRemoteApprovalEnabled(true, until: Date().addingTimeInterval(3600))
        session.disableRemoteApproval()
        XCTAssertFalse(session.isRemoteApprovalActive)
    }
}
