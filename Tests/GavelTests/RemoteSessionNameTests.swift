import XCTest
@testable import Gavel

final class RemoteSessionNameTests: XCTestCase {

    func testSessionStartPayloadDecodesSessionName() throws {
        let json = #"{"type":"SessionStart","session_id":"abc","cwd":"/tmp/x","session_name":"openspec-play"}"#
        let payload = try JSONDecoder().decode(SessionStartPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.sessionName, "openspec-play")
        XCTAssertEqual(payload.sessionId, "abc")
    }

    func testSessionStartPayloadSessionNameNilWhenAbsent() throws {
        let json = #"{"type":"SessionStart","session_id":"abc"}"#
        let payload = try JSONDecoder().decode(SessionStartPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.sessionName)
    }

    func testUpdateLabelAppliesExplicitNonDerivedName() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-remotename-\(UUID().uuidString)")
        let manager = SessionManager(homeDir: tmp, autoStartTimers: false, autoDiscover: false)
        let session = manager.session(for: 83001)
        session.sessionId = "sid-1"
        manager.updateLabel("openspec-play", on: session, sessionId: "sid-1")
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(session.label, "openspec-play")
        XCTAssertFalse(session.labelIsDerived)
    }
}
