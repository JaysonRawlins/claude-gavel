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

                Divider()

                bashExamples
                editExamples
                writeExamples
                readExamples
                globGrepExamples
                agentExamples
                mcpExamples
                wildcardExamples
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

    private func toolNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .italic()
    }

    // MARK: - Tool-Specific Example Sections

    private var bashExamples: some View {
        section("Bash Examples") {
            example("Block push to main/master",
                    "git\\s+push\\b.*\\b(main|master)\\b")
            example("Block force push anywhere",
                    "git\\s+push\\b.*(-f|--force)\\b")
            example("Block git reset --hard",
                    "git\\s+reset\\s+--hard")
            example("Allow git (except push)",
                    "git\\s+(?!push)\\w+")
            example("Allow npm/yarn commands",
                    "(npm|yarn)\\s+\\w+")
            example("Allow swift build/test only",
                    "swift\\s+(build|test)\\b")
            example("Block rm -rf outside /tmp",
                    "rm\\s+-\\w*r\\w*\\s+/(?!tmp)")
            example("Block secrets except safe flags",
                    "doppler\\s+secrets\\b(?!.*--only-names)")
            example("Block docker push",
                    "docker\\s+push\\b")
        }
    }

    private var editExamples: some View {
        section("Edit / MultiEdit Examples") {
            toolNote("Pattern matches against the file path")
            example("Allow edits under Sources/",
                    "Sources/.*")
            example("Block edits to config files",
                    "\\.(json|yaml|yml|toml)$")
            example("Allow edits to Swift files only",
                    ".*\\.swift$")
            example("Block edits to dotfiles",
                    "/Users/.*/\\.\\w+")
        }
    }

    private var writeExamples: some View {
        section("Write Examples") {
            toolNote("Pattern matches against the file path")
            example("Allow writes under src/",
                    "src/.*")
            example("Block writes to /tmp",
                    "/tmp/.*")
            example("Block writes to hidden dirs",
                    "/Users/.*/\\.\\w+/")
        }
    }

    private var readExamples: some View {
        section("Read Examples") {
            toolNote("Pattern matches against the file path")
            example("Allow reading any file",
                    "*")
            example("Block reading env files",
                    "\\.env(\\.local)?$")
        }
    }

    private var globGrepExamples: some View {
        section("Glob / Grep Examples") {
            toolNote("Pattern matches against the search path or pattern")
            example("Allow glob in project dirs",
                    "src/*")
            example("Allow grep in current project",
                    "/Users/.*/project/.*")
        }
    }

    private var agentExamples: some View {
        section("Agent Examples") {
            toolNote("Pattern matches against tool input fields")
            example("Allow all agent calls",
                    "*")
            example("Block agents with worktree type",
                    ".*worktree.*")
        }
    }

    private var mcpExamples: some View {
        section("MCP Tool Examples") {
            toolNote("Use tool * with regex, or set tool picker to the full MCP tool name")
            example("Block all Slack writes",
                    "mcp__.*[Ss]lack.*(send|update|delete)")
            example("Allow Slack reads",
                    "mcp__.*[Ss]lack.*(read|list|search)")
            example("Block all Jira writes",
                    "mcp__.*[Jj]ira.*(create|update|delete)")
            example("Block Playwright navigation",
                    "mcp__.*[Pp]laywright.*navigate$")
        }
    }

    private var wildcardExamples: some View {
        section("Wildcard (*) Tool Examples") {
            toolNote("Setting tool to * matches all tool types")
            example("Block anything touching .env",
                    "\\.env\\b")
            example("Ask before any destructive op",
                    "(rm|delete|drop|truncate)\\b")
        }
    }
}
