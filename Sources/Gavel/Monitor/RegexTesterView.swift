import SwiftUI

/// Interactive regex/glob tester with match highlighting.
struct RegexTesterView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pattern input
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pattern")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Regex", isOn: $viewModel.testerIsRegex)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.orange)
                }

                HStack(spacing: 2) {
                    if viewModel.testerIsRegex {
                        Text("/").font(.system(.body, design: .monospaced)).foregroundColor(.orange)
                    }
                    TextField(viewModel.testerIsRegex ? "regex pattern" : "glob pattern (* = wildcard)", text: $viewModel.testerPattern)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    if viewModel.testerIsRegex {
                        Text("/i").font(.system(.body, design: .monospaced)).foregroundColor(.orange)
                    }
                }
            }

            // Test string input
            VStack(alignment: .leading, spacing: 4) {
                Text("Test String")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                TextEditor(text: $viewModel.testerTestString)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            Divider()

            // Results
            if !viewModel.testerPattern.isEmpty && !viewModel.testerTestString.isEmpty {
                matchResults
            } else {
                Text("Enter a pattern and test string to see results.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var matchResults: some View {
        let compiled = compilePattern()

        switch compiled {
        case .failure(let error):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                Text(error)
                    .foregroundColor(.red)
                    .font(.body)
            }

        case .success(let regex):
            let matches = findMatches(regex: regex, in: viewModel.testerTestString)

            // Match/No Match badge
            HStack(spacing: 8) {
                if matches.isEmpty {
                    badge(text: "NO MATCH", color: .gray)
                } else {
                    badge(text: "\(matches.count) MATCH\(matches.count == 1 ? "" : "ES")", color: .green)
                }

                if !matches.isEmpty {
                    Text("Matched ranges shown below")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Highlighted test string
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Highlighted Matches")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    highlightedText(viewModel.testerTestString, matches: matches)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)

                    // Show matched substrings
                    ForEach(Array(matches.enumerated()), id: \.offset) { idx, match in
                        HStack(spacing: 4) {
                            Text("Match \(idx + 1):")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(match.value)
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundColor(.green)
                                .textSelection(.enabled)
                            Text("[\(match.range.location)...\(match.range.location + match.range.length)]")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Matching

    private struct MatchResult {
        let value: String
        let range: NSRange
    }

    private enum CompileResult {
        case success(NSRegularExpression)
        case failure(String)
    }

    private func compilePattern() -> CompileResult {
        if viewModel.testerIsRegex {
            do {
                let regex = try NSRegularExpression(pattern: viewModel.testerPattern, options: [.caseInsensitive])
                return .success(regex)
            } catch {
                return .failure("Invalid regex: \(error.localizedDescription)")
            }
        } else {
            if let regex = PersistentRule.compilePattern(viewModel.testerPattern, isRegex: false) {
                return .success(regex)
            }
            return .failure("Invalid glob pattern")
        }
    }

    private func findMatches(regex: NSRegularExpression, in string: String) -> [MatchResult] {
        let nsString = string as NSString
        let results = regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))
        return results.map { result in
            MatchResult(
                value: nsString.substring(with: result.range),
                range: result.range
            )
        }
    }

    // MARK: - Highlighted Text

    private func highlightedText(_ string: String, matches: [MatchResult]) -> some View {
        let attributed = buildAttributedString(string, matches: matches)
        return Text(attributed)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
    }

    private func buildAttributedString(_ string: String, matches: [MatchResult]) -> AttributedString {
        let nsString = string as NSString
        var result = AttributedString()
        var lastEnd = 0

        for match in matches {
            let matchStart = match.range.location
            let matchEnd = matchStart + match.range.length

            // Plain text before this match
            if matchStart > lastEnd {
                let before = nsString.substring(with: NSRange(location: lastEnd, length: matchStart - lastEnd))
                var part = AttributedString(before)
                part.font = .system(.body, design: .monospaced)
                result.append(part)
            }

            // Highlighted match
            let matched = nsString.substring(with: match.range)
            var part = AttributedString(matched)
            part.font = .system(.body, design: .monospaced).bold()
            part.foregroundColor = .white
            part.backgroundColor = .green
            result.append(part)

            lastEnd = matchEnd
        }

        // Remaining text
        if lastEnd < nsString.length {
            let remainder = nsString.substring(from: lastEnd)
            var part = AttributedString(remainder)
            part.font = .system(.body, design: .monospaced)
            result.append(part)
        }

        return result
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.body.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color)
            .cornerRadius(6)
    }
}
