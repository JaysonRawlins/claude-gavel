import Foundation

final class SkillTagHandler: JsonlEventHandler {
    let name = "skill-tag"

    private let knownSkills: Set<String>

    private static let commandNamePattern = try! NSRegularExpression(
        pattern: #"<command-name>\s*/?([A-Za-z0-9][\w-]*)\s*</command-name>"#
    )

    private static let markerPattern = try! NSRegularExpression(
        pattern: #"\[\[/([A-Za-z0-9][\w-]*)\]\]"#
    )

    private static let removeMarkerPattern = try! NSRegularExpression(
        pattern: #"\[\[-/([A-Za-z0-9][\w-]*)\]\]"#
    )

    init(knownSkills: Set<String> = SkillTagHandler.liveSkills) {
        self.knownSkills = knownSkills
    }

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        guard !knownSkills.isEmpty else { return }
        guard (event.json?["type"] as? String) == "user" else { return }
        let line = event.rawLine
        let at = Self.timestamp(from: event.json) ?? Date()
        let observed = tag(line: line, pattern: Self.commandNamePattern, source: .observed, at: at, session: session)
        let manual = tag(line: line, pattern: Self.markerPattern, source: .manual, at: at, session: session)
        let removed = untag(line: line, pattern: Self.removeMarkerPattern, session: session)
        if observed || manual || removed { manager.saveActiveSessions() }
    }

    private func untag(line: String, pattern: NSRegularExpression, session: Session) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        var removed = false
        for match in pattern.matches(in: line, range: range) {
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: line) else { continue }
            if session.tags.remove("skill:\(String(line[r]))") { removed = true }
        }
        return removed
    }

    private func tag(line: String, pattern: NSRegularExpression, source: TagSource, at: Date, session: Session) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        var added = false
        for match in pattern.matches(in: line, range: range) {
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: line) else { continue }
            let skill = String(line[r])
            guard knownSkills.contains(skill) else { continue }
            if session.tags.add("skill:\(skill)", at: at, source: source) { added = true }
        }
        return added
    }

    private static func timestamp(from json: [String: Any]?) -> Date? {
        guard let value = json?["timestamp"] as? String else { return nil }
        return isoFormatter.date(from: value)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let liveSkills: Set<String> = discoverSkills()

    static func discoverSkills(
        in directory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills")
    ) -> Set<String> {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        var skills = Set<String>()
        for name in names {
            var isDir: ObjCBool = false
            let full = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                skills.insert(name)
            }
        }
        return skills
    }
}
