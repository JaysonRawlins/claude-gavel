import Foundation

/// Shared arg-condition semantics for persistent AND session rules: every
/// condition regex must FULLY match (`\A(?:…)\z`) the stringified scalar arg.
/// Absent arg, non-scalar value, or an uncompilable pattern all fail closed —
/// the rule doesn't fire and evaluation falls through to the normal prompt.
enum ArgConditionMatcher {

    /// Anchor so a condition can't substring-match (`C123` must not pass
    /// `C1234`) and newlines can't smuggle a second value past the match.
    static func compileAnchored(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
    }

    /// Uncached evaluation — used by SessionRule (session-lifetime structs,
    /// low volume). PersistentRule keeps its own per-rule regex cache.
    static func satisfied(_ conditions: [String: String]?, by toolInput: [String: AnyCodable]?) -> Bool {
        guard let conditions, !conditions.isEmpty else { return true }
        for (arg, pattern) in conditions {
            guard let value = toolInput?[arg].flatMap(PersistentRule.scalarString),
                  let regex = compileAnchored(pattern),
                  regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            else { return false }
        }
        return true
    }
}
