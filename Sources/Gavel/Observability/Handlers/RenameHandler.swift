import Foundation

final class RenameHandler: JsonlEventHandler {
    let name = "rename"

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"<command-message>rename</command-message>[\s\S]*?<command-args>(.+?)</command-args>"#,
            #""type":"custom-title","customTitle":"([^"]*)""#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        guard let newLabel = extractLabel(from: event.rawLine) else { return }
        manager.updateLabel(newLabel, on: session, sessionId: event.sessionId)
    }

    private func extractLabel(from line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for regex in Self.patterns {
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: line) else { continue }
            let value = String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
