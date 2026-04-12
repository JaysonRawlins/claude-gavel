import Foundation

/// Shared pattern compilation for glob and regex matching.
/// Used by both SessionRule and PersistentRule to avoid duplicated glob→regex conversion.
enum PatternCompiler {

    /// Convert a glob pattern (`*` = any characters) to NSRegularExpression.
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

    /// Compile a pattern to NSRegularExpression.
    /// Glob patterns are converted to regex; regex patterns are used as-is (case-insensitive).
    static func compilePattern(_ pattern: String, isRegex: Bool) -> NSRegularExpression? {
        if isRegex {
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return compileGlob(pattern)
    }

    /// Test a pattern against a sample string. Returns match result and any compile error.
    static func testPattern(_ pattern: String, isRegex: Bool, against sample: String) -> (matches: Bool, error: String?) {
        guard let regex = compilePattern(pattern, isRegex: isRegex) else {
            return (false, isRegex ? "Invalid regex" : "Invalid pattern")
        }
        return (matches(regex, in: sample), nil)
    }

    /// Test if a compiled regex matches a string.
    static func matches(_ regex: NSRegularExpression, in string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
