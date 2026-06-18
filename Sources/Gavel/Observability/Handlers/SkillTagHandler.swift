import Foundation

final class SkillTagHandler: JsonlEventHandler {
    let name = "skill-tag"

    private let knownSkills: Set<String>

    private static let pattern = try! NSRegularExpression(
        pattern: #"<command-name>\s*/?([A-Za-z0-9][\w-]*)\s*</command-name>"#
    )

    init(knownSkills: Set<String> = SkillTagHandler.liveSkills) {
        self.knownSkills = knownSkills
    }

    func handle(_ event: JsonlEvent, manager: SessionManager, session: Session) {
        guard !knownSkills.isEmpty else { return }
        let line = event.rawLine
        let range = NSRange(line.startIndex..., in: line)
        let at = Self.timestamp(from: event.json) ?? Date()
        var added = false
        for match in Self.pattern.matches(in: line, range: range) {
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: line) else { continue }
            let skill = String(line[r])
            guard knownSkills.contains(skill) else { continue }
            if session.tags.addObserved("skill:\(skill)", at: at) { added = true }
        }
        if added { manager.saveActiveSessions() }
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
