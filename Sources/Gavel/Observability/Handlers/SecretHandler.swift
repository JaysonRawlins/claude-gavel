import Foundation

final class SecretHandler: JsonlEventHandler {
    let name = "secret"

    private static let cooldown: TimeInterval = 300

    private var lastFireByLabel: [String: Date] = [:]

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        let line = event.rawLine
        let range = NSRange(line.startIndex..., in: line)
        for pattern in SecretRedactor.patterns where pattern.regex.firstMatch(in: line, range: range) != nil {
            if let last = lastFireByLabel[pattern.label],
               Date().timeIntervalSince(last) < Self.cooldown {
                return
            }
            lastFireByLabel[pattern.label] = Date()
            let sessionTag = session.label.isEmpty ? "PID \(session.pid)" : session.label
            GavelNotifications.notify(
                title: "Gavel",
                body: "⚠️ Secret detected — \(pattern.label)\n\nSession: \(sessionTag)\n\nReview the conversation transcript before continuing.",
                critical: true
            )
            return
        }
    }
}
