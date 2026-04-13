import SwiftUI

/// Static regex quick reference card.
struct RegexCheatSheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Anchors") {
                    row("^", "Start of string")
                    row("$", "End of string")
                    row("\\b", "Word boundary")
                    row("\\B", "Non-word boundary")
                }

                section("Character Classes") {
                    row(".", "Any character (except newline)")
                    row("\\d", "Digit [0-9]")
                    row("\\D", "Non-digit")
                    row("\\w", "Word character [a-zA-Z0-9_]")
                    row("\\W", "Non-word character")
                    row("\\s", "Whitespace (space, tab, newline)")
                    row("\\S", "Non-whitespace")
                    row("[abc]", "Any of a, b, or c")
                    row("[^abc]", "Not a, b, or c")
                    row("[a-z]", "Range: a through z")
                }

                section("Quantifiers") {
                    row("*", "0 or more (greedy)")
                    row("+", "1 or more (greedy)")
                    row("?", "0 or 1 (optional)")
                    row("{3}", "Exactly 3")
                    row("{3,}", "3 or more")
                    row("{3,5}", "Between 3 and 5")
                    row("*?", "0 or more (lazy/non-greedy)")
                    row("+?", "1 or more (lazy/non-greedy)")
                }

                section("Groups & Lookaround") {
                    row("(abc)", "Capture group")
                    row("(?:abc)", "Non-capturing group")
                    row("a|b", "Alternation (a or b)")
                    row("(?=abc)", "Positive lookahead")
                    row("(?!abc)", "Negative lookahead")
                    row("(?<=abc)", "Positive lookbehind")
                    row("(?<!abc)", "Negative lookbehind")
                }

                section("Escaping") {
                    row("\\", "Escape next character")
                    row("\\.", "Literal dot")
                    row("\\(", "Literal parenthesis")
                    row("\\\\", "Literal backslash")
                }

                section("Gavel Glob Patterns") {
                    row("*", "Match any characters (like .*)")
                    row("swift build*", "Matches 'swift build -c release'")
                    row("Sources/*", "Matches any path under Sources/")
                }

                section("Common Gavel Patterns") {
                    example("Block git push to main",
                            "git\\s+push\\b.*\\b(main|master)\\b")
                    example("Allow git but not push",
                            "git\\s+(?!push)\\w+")
                    example("Block secrets except --only-names",
                            "doppler\\s+secrets\\b(?!.*--only-names)")
                    example("Allow npm/yarn commands",
                            "(npm|yarn)\\s+\\w+")
                }
            }
            .padding(12)
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.body, design: .default).bold())
                .foregroundColor(.primary)

            content()
        }
    }

    private func row(_ pattern: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(pattern)
                .foregroundColor(.orange)
                .frame(width: 100, alignment: .leading)

            Text(description)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private func example(_ label: String, _ pattern: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundColor(.secondary)
                .font(.caption)
            Text(pattern)
                .foregroundColor(.green)
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1))
                .cornerRadius(3)
        }
    }
}
