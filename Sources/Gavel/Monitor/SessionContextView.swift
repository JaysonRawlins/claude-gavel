import SwiftUI

/// Editor for ~/.claude/gavel/session-context.md — injected into every Claude Code session.
struct SessionContextView: View {
    @State private var content: String = ""
    @State private var savedContent: String = ""
    @State private var statusMessage: String?

    private static let contextPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/gavel/session-context.md")

    private var hasChanges: Bool { content != savedContent }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Context")
                        .font(.headline)
                    Text("Injected into every Claude Code session at startup")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                Button(action: openInEditor) {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in your default .md editor")

                Button(action: save) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasChanges)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding(4)
        }
        .onAppear { load() }
    }

    private func load() {
        let path = Self.contextPath.path
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            content = text
            savedContent = text
        }
    }

    private func save() {
        do {
            try content.write(to: Self.contextPath, atomically: true, encoding: .utf8)
            savedContent = content
            statusMessage = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if statusMessage == "Saved" { statusMessage = nil }
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func openInEditor() {
        if !FileManager.default.fileExists(atPath: Self.contextPath.path) {
            save()
        }
        EditorPreference.open(Self.contextPath)
    }
}
