import Foundation

/// One conversational turn extracted from a transcript for the History viewer.
struct TranscriptMessage: Identifiable {
    enum Role { case user, assistant }
    let id: Int
    let role: Role
    let text: String
}

/// Parses a Claude Code JSONL transcript into a readable user/assistant message
/// list. Tool calls, tool results, meta lines, and `<…>`-wrapped envelopes
/// (system reminders, slash-command tags) are dropped — only conversational text
/// survives, so a session can be recognized at a glance. Best-effort: a missing
/// file or a malformed line yields fewer messages, never a throw.
enum TranscriptReader {
    /// Per-message cap so one giant paste can't make the viewer unscrollable.
    static let maxMessageLength = 4000

    static func messages(cwd: String, sessionId: String) -> [TranscriptMessage] {
        guard let text = JsonlRenameReader.transcriptText(cwd: cwd, sessionId: sessionId) else { return [] }
        var messages: [TranscriptMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (role, body) = turn(fromLine: String(line)) else { continue }
            messages.append(TranscriptMessage(id: messages.count, role: role, text: body))
        }
        return messages
    }

    private static func turn(fromLine line: String) -> (TranscriptMessage.Role, String)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["isMeta"] as? Bool) != true,
              let message = obj["message"] as? [String: Any] else { return nil }

        let role: TranscriptMessage.Role
        switch obj["type"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        guard let body = conversationalText(message["content"]) else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A user line that only carried a tool_result, or a system-reminder /
        // slash-command envelope, has no conversation — drop it.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return (role, truncate(trimmed))
    }

    private static func conversationalText(_ content: Any?) -> String? {
        if let str = content as? String { return str }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            (part["type"] as? String) == "text" ? part["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxMessageLength else { return text }
        return String(text.prefix(maxMessageLength)) + "…"
    }
}
