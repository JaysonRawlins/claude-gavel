import Foundation

final class JsonlEventDispatcher {
    private let handlers: [JsonlEventHandler]
    private weak var manager: SessionManager?
    private weak var session: Session?

    init(handlers: [JsonlEventHandler], manager: SessionManager, session: Session) {
        self.handlers = handlers
        self.manager = manager
        self.session = session
    }

    func dispatch(_ rawLine: String) {
        guard let manager = manager, let session = session else { return }
        guard let sid = session.sessionId, let cwd = session.cwd else { return }

        let json = parseJson(rawLine)
        let event = JsonlEvent(rawLine: rawLine, json: json, sessionId: sid, cwd: cwd)

        for handler in handlers {
            let start = Date()
            handler.handle(event, manager: manager, session: session)
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            if elapsedMs > 5 {
                gavelLog("[obs] handler=\(handler.name) elapsed=\(Int(elapsedMs))ms")
            }
        }
    }

    private func parseJson(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
