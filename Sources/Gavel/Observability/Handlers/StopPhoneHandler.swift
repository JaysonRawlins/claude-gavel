import Foundation

final class StopPhoneHandler: JsonlEventHandler {
    let name = "stop-phone"

    private static let pattern = try! NSRegularExpression(
        pattern: #"\[\[/stop-phone\]\]"#, options: [.caseInsensitive]
    )

    static func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, range: range) != nil
    }

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        guard (event.json?["type"] as? String) == "user" else { return }
        guard Self.matches(event.rawLine) else { return }
        manager.stopAllPhone(reason: "[[/stop-phone]] in transcript (pid \(session.pid))")
    }
}
