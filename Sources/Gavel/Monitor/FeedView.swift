import SwiftUI

/// Live scrolling feed of hook events.
struct FeedView: View {
    let entries: [FeedDisplayEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in
                        FeedRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: entries.count) { _ in
                if let last = entries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FeedRow: View {
    let entry: FeedDisplayEntry

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(entry.timestamp)
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)

            switch entry.kind {
            case .toolCall(let tool, let summary):
                Text(tool)
                    .fontWeight(.bold)
                    .foregroundColor(colorForTool(tool))
                    .frame(width: 80, alignment: .leading)
                Text(summary)
                    .foregroundColor(.primary)
                    .lineLimit(3)

            case .decision(let badge, let reason):
                Text("")
                    .frame(width: 80)
                Text("\u{2192} \(badge.rawValue)")
                    .fontWeight(.semibold)
                    .foregroundColor(colorForBadge(badge))
                if let reason = reason, [DecisionBadge.block, .paused].contains(badge) {
                    Text(reason)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

            case .toolResult(let output):
                Text("")
                    .frame(width: 80)
                Text("\u{2508} \(output)")
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                    .font(.system(.caption2, design: .monospaced))

            case .stop:
                Text("Ready for your input")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)

            case .prompt(let text):
                Text("PROMPT")
                    .fontWeight(.bold)
                    .foregroundColor(.cyan)
                    .frame(width: 80, alignment: .leading)
                Text(text)
                    .foregroundColor(.primary)
                    .lineLimit(3)

            case .system(let message):
                Text("[system]")
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(message)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private func colorForTool(_ tool: String) -> Color {
        switch tool {
        case "Bash": return .orange
        case "Edit", "MultiEdit": return .blue
        case "Write": return .green
        case "Read", "Glob", "Grep": return .gray
        default: return .primary
        }
    }

    private func colorForBadge(_ badge: DecisionBadge) -> Color {
        switch badge {
        case .allow: return .green
        case .autoApprove: return .purple
        case .sandbox: return .orange
        case .block: return .red
        case .paused: return .yellow
        }
    }
}

// MARK: - Display Model

struct FeedDisplayEntry: Identifiable {
    let id: UUID
    let timestamp: String
    let kind: FeedEntryKind

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(from entry: FeedEntry) {
        self.id = UUID()
        let formatter = Self.timeFormatter

        switch entry {
        case .toolCall(_, _, _, let date),
             .decision(_, _, _, let date),
             .toolResult(_, _, let date),
             .prompt(_, _, let date),
             .stop(_, let date),
             .system(_, _, let date):
            self.timestamp = formatter.string(from: date)
        }

        switch entry {
        case .toolCall(let tool, let summary, _, _):
            self.kind = .toolCall(tool: tool, summary: summary)
        case .decision(let badge, let reason, _, _):
            self.kind = .decision(badge: badge, reason: reason)
        case .toolResult(let output, _, _):
            self.kind = .toolResult(output: String(output.prefix(500)))
        case .prompt(let text, _, _):
            self.kind = .prompt(text: text)
        case .stop(_, _):
            self.kind = .stop
        case .system(let msg, _, _):
            self.kind = .system(message: msg)
        }
    }
}

enum FeedEntryKind {
    case toolCall(tool: String, summary: String)
    case decision(badge: DecisionBadge, reason: String?)
    case toolResult(output: String)
    case prompt(text: String)
    case stop
    case system(message: String)
}
