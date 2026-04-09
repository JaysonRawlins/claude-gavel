import SwiftUI

/// The interactive approval dialog shown for each PreToolUse event.
struct ApprovalPanelView: View {
    @ObservedObject var coordinator: ApprovalCoordinator
    @State private var sessionPattern: String = ""
    @State private var noteToClaudeText: String = ""
    @State private var editedCommand: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if let approval = coordinator.currentApproval {
                toolHeader(approval)
                Divider()
                toolDetails(approval)
                Divider()
                noteToClaudeField()
                Divider()
                actionBar(approval)
            } else {
                Text("Waiting for tool calls...")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 300)
        .onChange(of: coordinator.currentApproval?.timestamp) { _ in
            resetFields()
        }
        .onAppear {
            resetFields()
        }
    }

    private func resetFields() {
        if let a = coordinator.currentApproval {
            sessionPattern = SessionRule.suggestPattern(
                toolName: a.payload.toolName,
                command: a.payload.command,
                filePath: a.payload.filePath
            )
            editedCommand = a.payload.command ?? ""
            noteToClaudeText = ""
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func toolHeader(_ approval: ApprovalCoordinator.PendingApproval) -> some View {
        HStack {
            Image(systemName: iconForTool(approval.payload.toolName))
                .font(.title2)
                .foregroundColor(colorForTool(approval.payload.toolName))

            Text(approval.payload.toolName)
                .font(.title2.bold())
                .foregroundColor(colorForTool(approval.payload.toolName))

            Spacer()

            if coordinator.queueCount > 0 {
                Text("+\(coordinator.queueCount) queued")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }

            Text("PID \(approval.session.pid)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tool Details

    @ViewBuilder
    private func toolDetails(_ approval: ApprovalCoordinator.PendingApproval) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch approval.payload.toolName {
                case "Bash":
                    bashDetails(approval.payload)
                case "Edit", "MultiEdit":
                    editDetails(approval.payload)
                case "Write":
                    writeDetails(approval.payload)
                case "Read":
                    readDetails(approval.payload)
                case "Glob":
                    globDetails(approval.payload)
                case "Grep":
                    grepDetails(approval.payload)
                default:
                    genericDetails(approval.payload)
                }

                if let cwd = approval.payload.cwd {
                    labeledField("CWD", value: cwd)
                }
            }
            .padding(12)
        }
    }

    private func bashDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command (editable)")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            TextEditor(text: $editedCommand)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 40, maxHeight: 120)
                .padding(4)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(editedCommand != (payload.command ?? "") ? Color.orange : Color.orange.opacity(0.2), lineWidth: editedCommand != (payload.command ?? "") ? 2 : 1)
                )

            if editedCommand != (payload.command ?? "") {
                Text("Modified — original will be replaced")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if let desc = payload.toolInput["description"]?.stringValue {
                labeledField("Description", value: desc)
            }
        }
    }

    private func editDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = payload.filePath {
                labeledField("File", value: path)
            }

            if let old = payload.toolInput["old_string"]?.stringValue {
                Text("Remove")
                    .font(.caption.bold())
                    .foregroundColor(.red)
                codeBlock(old, color: .red)
            }

            if let new = payload.toolInput["new_string"]?.stringValue {
                Text("Insert")
                    .font(.caption.bold())
                    .foregroundColor(.green)
                codeBlock(new, color: .green)
            }
        }
    }

    private func writeDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = payload.filePath {
                labeledField("File", value: path)
            }
            if let content = payload.toolInput["content"]?.stringValue {
                Text("Content")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                codeBlock(String(content.prefix(2000)), color: .green)
            }
        }
    }

    private func readDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = payload.filePath {
                labeledField("File", value: path)
            }
        }
    }

    private func globDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pattern = payload.toolInput["pattern"]?.stringValue {
                labeledField("Pattern", value: pattern)
            }
            if let path = payload.toolInput["path"]?.stringValue {
                labeledField("Path", value: path)
            }
        }
    }

    private func grepDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pattern = payload.toolInput["pattern"]?.stringValue {
                labeledField("Pattern", value: pattern)
            }
            if let path = payload.toolInput["path"]?.stringValue {
                labeledField("Path", value: path)
            }
            if let glob = payload.toolInput["glob"]?.stringValue {
                labeledField("Glob", value: glob)
            }
        }
    }

    private func genericDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(payload.toolInput.keys.sorted()), id: \.self) { key in
                if let value = payload.toolInput[key]?.stringValue {
                    labeledField(key, value: value)
                }
            }
        }
    }

    // MARK: - Note to Claude

    @ViewBuilder
    private func noteToClaudeField() -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "bubble.left")
                .foregroundColor(.secondary)
                .padding(.top, 4)
            TextField("Note to Claude (optional — Claude sees this as context)", text: $noteToClaudeText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private func actionBar(_ approval: ApprovalCoordinator.PendingApproval) -> some View {
        VStack(spacing: 6) {
            // Pattern field (shared by session and persistent rules)
            HStack(spacing: 4) {
                Text("\(approval.payload.toolName):")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(colorForTool(approval.payload.toolName))
                TextField("pattern", text: $sessionPattern)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }

            // Persistent + session rules row
            HStack(spacing: 6) {
                Button(action: {
                    coordinator.handleAction(.alwaysDenyPattern(pattern: sessionPattern))
                }) {
                    Label("Always Deny", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(action: {
                    coordinator.handleAction(.alwaysAllowPattern(pattern: sessionPattern))
                }) {
                    Label("Always Allow", systemImage: "shield.checkered")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Spacer()

                Button(action: {
                    coordinator.handleAction(.allowPatternForSession(
                        pattern: sessionPattern,
                        context: noteToClaudeText.isEmpty ? nil : noteToClaudeText,
                        updatedCommand: cmdIfModified
                    ))
                }) {
                    Label("Session Allow", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .keyboardShortcut("s", modifiers: [.command])
            }

            // One-time actions
            HStack {
                Button(action: {
                    coordinator.handleAction(.deny(
                        context: noteToClaudeText.isEmpty ? nil : noteToClaudeText
                    ))
                }) {
                    Label("Deny", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(action: {
                    coordinator.handleAction(.allow(
                        context: noteToClaudeText.isEmpty ? nil : noteToClaudeText,
                        updatedCommand: cmdIfModified
                    ))
                }) {
                    Label("Allow Once", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Returns the edited command only if it differs from the original.
    private var cmdIfModified: String? {
        guard let original = coordinator.currentApproval?.payload.command else { return nil }
        return editedCommand != original ? editedCommand : nil
    }

    // MARK: - Helpers

    private func labeledField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func codeBlock(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
    }

    private func iconForTool(_ tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        default:
            if tool.hasPrefix("mcp__") { return "server.rack" }
            return "wrench"
        }
    }

    private func colorForTool(_ tool: String) -> Color {
        switch tool {
        case "Bash": return .orange
        case "Edit", "MultiEdit": return .blue
        case "Write": return .green
        case "Read", "Glob", "Grep": return .gray
        case "Agent": return .purple
        default: return .primary
        }
    }
}
