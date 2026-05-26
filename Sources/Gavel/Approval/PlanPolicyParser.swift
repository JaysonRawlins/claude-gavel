import Foundation

/// A plan-declared approval rule, parsed from a ```gavel-policy fenced block in
/// a plan markdown file and layered onto a session as an overlay while the plan
/// is engaged.
///
/// Allow rules are segment-safe: every `&&`/`||`/`;`/`|` segment of a Bash
/// command must match, so an authorized prefix like `cdk deploy*` can't smuggle
/// a chained `curl evil`. Deny rules match if ANY segment matches, so a
/// prohibited command can't hide behind a benign prefix.
struct PlanPolicyRule {
    let toolName: String
    let pattern: String
    let isRegex: Bool
    let verdict: DecisionVerdict
    let explanation: String?
    private let regex: NSRegularExpression?

    init(toolName: String, pattern: String, isRegex: Bool, verdict: DecisionVerdict, explanation: String? = nil) {
        self.toolName = toolName
        self.pattern = pattern
        self.isRegex = isRegex
        self.verdict = verdict
        self.explanation = explanation
        self.regex = PatternCompiler.compilePattern(pattern, isRegex: isRegex)
    }

    func matches(toolName: String, command: String?, filePath: String?) -> Bool {
        guard self.toolName == toolName || self.toolName == "*", let regex else { return false }
        if toolName == "Bash" {
            let segments = SessionRule.splitCommandSegments(Self.sanitize(command ?? ""))
            guard !segments.isEmpty else { return false }
            return verdict == .allow
                ? segments.allSatisfy { PatternCompiler.matches(regex, in: $0) }
                : segments.contains { PatternCompiler.matches(regex, in: $0) }
        }
        let target = Self.sanitize(filePath ?? command ?? "")
        return PatternCompiler.matches(regex, in: target)
            || PatternCompiler.matches(regex, in: toolName)
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2013}", with: "-")
         .replacingOccurrences(of: "\u{2014}", with: "--")
         .replacingOccurrences(of: "\u{2012}", with: "-")
    }
}

/// Parses the first ```gavel-policy fenced block in a plan's markdown into
/// session overlay rules. No YAML dependency — one rule per line:
///
///     allow Bash: cdk deploy GreenfieldStack*
///     deny  Bash: cdk destroy*
///     block Bash: re:terraform\s+destroy
///
/// Grammar: `<allow|deny|block> <ToolName>: <pattern>`. Pattern is glob by
/// default; a `re:` prefix marks it regex. `deny` maps to a prompt (force
/// dialog); `block` is a hard deny. Blank lines, `#` comments, and lines that
/// don't parse are skipped.
enum PlanPolicyParser {
    static func parse(_ planText: String) -> [PlanPolicyRule] {
        guard let body = fencedBlock(in: planText) else { return [] }
        var rules: [PlanPolicyRule] = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let rule = parseLine(line) { rules.append(rule) }
        }
        return rules
    }

    private static func fencedBlock(in text: String) -> String? {
        var collecting = false
        var collected: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !collecting {
                if trimmed == "```gavel-policy" || trimmed == "~~~gavel-policy" { collecting = true }
            } else if trimmed == "```" || trimmed == "~~~" {
                return collected.joined(separator: "\n")
            } else {
                collected.append(line)
            }
        }
        return collecting ? collected.joined(separator: "\n") : nil
    }

    private static func parseLine(_ line: String) -> PlanPolicyRule? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard head.count == 2 else { return nil }

        let verdict: DecisionVerdict
        switch head[0].lowercased() {
        case "allow": verdict = .allow
        case "deny": verdict = .prompt
        case "block": verdict = .block
        default: return nil
        }

        var pattern = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        var isRegex = false
        if pattern.hasPrefix("re:") {
            isRegex = true
            pattern = String(pattern.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return PlanPolicyRule(toolName: head[1], pattern: pattern, isRegex: isRegex, verdict: verdict)
    }
}
