import XCTest
@testable import Gavel

final class RenameHandlerTests: XCTestCase {

    private func isolatedManager() -> SessionManager {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gavel-rename-tests-\(UUID().uuidString)")
        return SessionManager(homeDir: tmp, autoStartTimers: false, autoDiscover: false)
    }

    private func event(_ line: String) -> JsonlEvent {
        JsonlEvent(rawLine: line, json: nil, sessionId: "s", cwd: "/tmp")
    }

    private func drainMain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    func testCustomTitleLineSetsExplicitLabel() {
        let manager = isolatedManager()
        let session = manager.session(for: 82001)
        RenameHandler().handle(
            event(#"{"type":"custom-title","customTitle":"personal-assistant-jun","sessionId":"s"}"#),
            manager: manager, session: session)
        drainMain()
        XCTAssertEqual(session.label, "personal-assistant-jun")
        XCTAssertFalse(session.labelIsDerived)
    }

    func testRenameCommandBlockSetsLabel() {
        let manager = isolatedManager()
        let session = manager.session(for: 82002)
        RenameHandler().handle(
            event("<command-message>rename</command-message> x <command-args>my-new-name</command-args>"),
            manager: manager, session: session)
        drainMain()
        XCTAssertEqual(session.label, "my-new-name")
        XCTAssertFalse(session.labelIsDerived)
    }

    func testNonMatchingLineLeavesLabelUnchanged() {
        let manager = isolatedManager()
        let session = manager.session(for: 82003)
        session.label = "keep-me"
        session.labelIsDerived = true
        RenameHandler().handle(event(#"{"type":"user","message":"hello"}"#),
                               manager: manager, session: session)
        drainMain()
        XCTAssertEqual(session.label, "keep-me")
        XCTAssertTrue(session.labelIsDerived)
    }
}
