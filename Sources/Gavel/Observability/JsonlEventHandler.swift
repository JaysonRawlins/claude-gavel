import Foundation

struct JsonlEvent {
    let rawLine: String
    let json: [String: Any]?
    let sessionId: String
    let cwd: String
}

protocol JsonlEventHandler {
    var name: String { get }
    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session)
}
