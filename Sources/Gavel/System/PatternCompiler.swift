import Foundation

/// Shared glob/regex compilation used by both `SessionRule` and `PersistentRule` — single source of truth for `*` → `.*` conversion.
enum PatternCompiler {
    /// Convert a glob (`*` = any) to anchored NSRegularExpression; non-glob metachars are escaped.
    static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case ".", "(", ")", "[", "]", "{", "}", "\\", "^", "$", "|", "+", "?":
                regex += "\\\(ch)"
            default: regex += String(ch)
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex)
    }

    /// Compile a pattern — globs convert to regex; regex is used as-is, case-insensitive.
    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        if isRegex {
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return compileGlob(pattern)
    }

    /// Test a pattern against a sample, surfacing compile errors so the panel can show them inline.
    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        guard let regex = compilePattern(pattern, isRegex: isRegex) else {
            return (false, isRegex ? "Invalid regex" : "Invalid pattern")
        }
        return (matches(regex, in: sample), nil)
    }

    static func matches(_ regex: NSRegularExpression, in string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// Detect regex-specific syntax that would be escaped (and broken) under glob compilation — used to auto-enable the Regex toggle when users paste regex patterns.
    static func looksLikeRegex(_ pattern: String) -> Bool {
        if pattern.range(of: #"\\[swdbSWDB]"#, options: .regularExpression) != nil { return true } // \s \w \d \b
        if pattern.contains("(") || pattern.contains("|") { return true }                          // grouping / alternation
        if pattern.contains("+") || pattern.contains("?") { return true }                          // quantifiers glob doesn't have
        if pattern.contains("[") { return true }                                                   // character classes
        if pattern.hasPrefix("^") || pattern.hasSuffix("$") { return true }                        // anchors (glob adds these)
        if pattern.range(of: #"\{\d"#, options: .regularExpression) != nil { return true }         // {n} / {n,m}
        return false
    }
}
