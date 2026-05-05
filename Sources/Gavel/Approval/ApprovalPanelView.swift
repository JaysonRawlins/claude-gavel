import SwiftUI

/// All state for the note-to-Claude field, hoisted into an ObservableObject so
/// the field's sub-view can observe it independently of the parent panel.
/// Rationale: when the user clicks the in-field checkbox, only `NoteField`
/// needs to re-render — the action buttons (Allow/Deny) live in the parent
/// body and shouldn't get torn down by an unrelated state change. An earlier
/// `@State`-on-parent design wedged the daemon when the user toggled the
/// checkbox and then clicked Deny: the parent body re-rendered, the
/// floating-panel checkbox lost / shuffled key-responder status, and the
/// subsequent Deny click never reached `coordinator.handleAction`. Isolating
/// the state plus replacing `Toggle.checkbox` with a `Button`-styled checkbox
/// (which doesn't carry the same NSButton focus quirks in utility panels)
/// removes both vectors.
final class NoteFieldState: ObservableObject {
    @Published var text: String = ""
    @Published var sendToClaude: Bool = false
    @Published var hasBeenEdited: Bool = false
    var seeded: String = ""

    /// True when the field still shows the auto-seeded preview (i.e. user
    /// hasn't edited). Drives italic + secondary text styling.
    var notePreviewActive: Bool {
        !hasBeenEdited && !seeded.isEmpty && text == seeded
    }

    /// Note value to send as `additionalContext` on Allow paths. nil unless
    /// the user explicitly opted in (checkbox or edit-auto-tick) AND there's
    /// non-empty text.
    var noteForAllowContext: String? {
        guard sendToClaude, !text.isEmpty else { return nil }
        return text
    }

    /// Note value to send as the deny reason. Gated on `hasBeenEdited` rather
    /// than the checkbox: a typed deny reason is always high-signal, but the
    /// auto-seeded preview ("User approved this via Gavel") is nonsensical
    /// as a deny reason and must not flow on a no-edit deny.
    var noteForDenyContext: String? {
        guard hasBeenEdited, !text.isEmpty else { return nil }
        return text
    }

    func reset(seededText: String) {
        text = seededText
        seeded = seededText
        hasBeenEdited = false
        sendToClaude = false
    }

    /// Called from the field's `onChange`. Promotes the first text mutation
    /// to "user has edited" + auto-ticks the send checkbox.
    func userEditedIfNeeded() {
        if !hasBeenEdited && text != seeded {
            hasBeenEdited = true
            sendToClaude = true
        }
    }
}

/// The interactive approval dialog shown for each PreToolUse event.
/// Each session gets its own panel via SessionPanel.
struct ApprovalPanelView: View {
    @ObservedObject var coordinator: ApprovalCoordinator
    @ObservedObject var sessionPanel: ApprovalCoordinator.SessionPanel
    @State private var sessionPattern: String = ""
    @State private var editedCommand: String = ""
    @State private var editedFields: [String: String] = [:]
    @State private var isRegexMode: Bool = false

    /// All note-field state lives here. See `NoteFieldState` for the
    /// architectural rationale (re-render isolation + bug fix).
    @StateObject private var noteState = NoteFieldState()

    var body: some View {
        VStack(spacing: 0) {
            if let approval = sessionPanel.currentApproval {
                toolHeader(approval)
                if let reason = approval.triggerReason, !reason.isEmpty {
                    triggerBanner(reason)
                }
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
        .onChange(of: sessionPanel.currentApproval?.timestamp) { _ in
            resetFields()
        }
        .onAppear {
            resetFields()
        }
    }

    private func resetFields() {
        if let a = sessionPanel.currentApproval {
            sessionPattern = SessionRule.suggestPattern(
                toolName: a.payload.toolName,
                command: a.payload.command,
                filePath: a.payload.filePath
            )
            editedCommand = ApprovalCoordinator.sanitizeDashes(a.payload.command ?? "")
            editedFields = [:]
            // Seed the note field as a *preview* of what would flow to Claude
            // if the user opts in. Default-tier prompts (no rule fired) get a
            // generic canned line so the opt-in path is consistent.
            let seeded: String
            if let reason = a.triggerReason, !reason.isEmpty {
                seeded = "User approved this via Gavel — \(reason)"
            } else {
                seeded = "User approved this via Gavel"
            }
            noteState.reset(seededText: seeded)
            isRegexMode = false
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

            if sessionPanel.queueCount > 0 {
                Text("+\(sessionPanel.queueCount) queued")
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

    // MARK: - Trigger Banner

    @ViewBuilder
    private func triggerBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Triggered by Gavel rule")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(reason)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
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

            // Size editor to content: ~18pt per line, min 3 lines, max 20 lines.
            // Wrapping estimate: assume ~80 chars per line at monospaced body size.
            let newlineCount = editedCommand.components(separatedBy: .newlines).count
            let wrapEstimate = max(1, editedCommand.count / 80)
            let lineCount = max(6, max(newlineCount, wrapEstimate) + 1)
            let height = CGFloat(min(lineCount, 20)) * 18

            TextEditor(text: $editedCommand)
                .font(.system(.body, design: .monospaced))
                .frame(height: height)
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

    /// Keys whose values are editable in the approval panel (message content, post text, etc.)
    private static let editableKeys: Set<String> = [
        "text", "message", "body", "content", "description", "comment", "prompt", "query"
    ]

    private func genericDetails(_ payload: PreToolUsePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(payload.toolInput.keys.sorted()), id: \.self) { key in
                if let value = payload.toolInput[key]?.stringValue {
                    if Self.editableKeys.contains(key) {
                        editableField(key, original: value)
                    } else {
                        labeledField(key, value: value)
                    }
                }
            }
        }
    }

    private func editableField(_ key: String, original: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(key) (editable)")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            let binding = Binding<String>(
                get: { editedFields[key] ?? original },
                set: { editedFields[key] = $0 }
            )
            let isModified = (editedFields[key] ?? original) != original

            TextEditor(text: binding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 200)
                .padding(4)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isModified ? Color.orange : Color.blue.opacity(0.2), lineWidth: isModified ? 2 : 1)
                )

            if isModified {
                Text("Modified — original will be replaced")
                    .font(.caption2)
                    .foregroundColor(.orange)
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
            NoteField(state: noteState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private func actionBar(_ approval: ApprovalCoordinator.PendingApproval) -> some View {
        VStack(spacing: 6) {
            // Pattern field with regex toggle
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(approval.payload.toolName):")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundColor(colorForTool(approval.payload.toolName))

                    if isRegexMode {
                        Text("/")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    if isRegexMode {
                        Text("/")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                    }

                    Toggle("Regex", isOn: $isRegexMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    .tint(.orange)
                }

                TextEditor(text: $sessionPattern)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 54)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .onChange(of: sessionPattern) { pattern in
                        if !isRegexMode && PatternCompiler.looksLikeRegex(pattern) {
                            isRegexMode = true
                        }
                    }
            }

            // Live pattern tester
            patternTester(approval)

            // Persistent + session rules row
            HStack(spacing: 6) {
                Button(action: {
                    coordinator.handleAction(.alwaysDenyPattern(pattern: sessionPattern, isRegex: isRegexMode, explanation: noteState.noteForDenyContext), on: sessionPanel)
                }) {
                    Label("Always Deny", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(action: {
                    coordinator.handleAction(.alwaysAllowPattern(pattern: sessionPattern, isRegex: isRegexMode), on: sessionPanel)
                }) {
                    Label("Always Allow", systemImage: "shield.checkered")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button(action: {
                    coordinator.handleAction(.alwaysPromptPattern(pattern: sessionPattern, isRegex: isRegexMode), on: sessionPanel)
                }) {
                    Label("Always Prompt", systemImage: "bell.badge")
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Spacer()

                Button(action: {
                    coordinator.handleAction(.denyPatternForSession(
                        pattern: sessionPattern,
                        explanation: noteState.noteForDenyContext
                    ), on: sessionPanel)
                }) {
                    Label("Session Deny", systemImage: "shield.slash")
                }
                .buttonStyle(.bordered)
                .tint(.pink)
                .keyboardShortcut("d", modifiers: [.command])

                Button(action: {
                    coordinator.handleAction(.allowPatternForSession(
                        pattern: sessionPattern,
                        context: noteState.noteForAllowContext,
                        updatedCommand: cmdIfModified,
                        updatedInput: updatedInputIfModified
                    ), on: sessionPanel)
                    coordinator.sessionManager?.noteInteraction()
                }) {
                    Label("Session Allow", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .keyboardShortcut("s", modifiers: [.command])
            }

            // One-time actions
            HStack {
                Button(action: { performDeny() }) {
                    Label("Deny", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                // Modifier required so a stray Escape press (TextEditor
                // dismiss, accidental key) doesn't reject an in-flight
                // approval. Cmd+Escape mirrors the Cmd+Return convention
                // used for Allow Once.
                .keyboardShortcut(.escape, modifiers: [.command])

                Button(action: {
                    if let approval = sessionPanel.currentApproval {
                        approval.session.revokeAutoApprove()
                    }
                    coordinator.sessionManager?.noteInteraction()
                }) {
                    Label("Prompt", systemImage: "questionmark.bubble")
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .help("Turn off auto + sub-agent inherit for this session. Current call still needs Allow/Deny.")

                Spacer()

                Button(action: { performAllowOnce() }) {
                    Label("Allow Once", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                // Cmd+Return only — plain Return alone too easily fires Allow
                // on macOS (TextEditor doesn't always capture it), and an
                // accidental approval is a real cost. Both action shortcuts
                // (Cmd+Return / Cmd+Escape) require the Cmd modifier for
                // symmetry and to prevent stray-key triggering.
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Trigger the Allow Once action. Extracted so the visible button and
    /// the hidden Cmd+Return shortcut button can share one implementation.
    private func performAllowOnce() {
        coordinator.handleAction(.allow(
            context: noteState.noteForAllowContext,
            updatedCommand: cmdIfModified,
            updatedInput: updatedInputIfModified
        ), on: sessionPanel)
        coordinator.sessionManager?.noteInteraction()
    }

    private func performDeny() {
        coordinator.handleAction(.deny(
            context: noteState.noteForDenyContext
        ), on: sessionPanel)
        coordinator.sessionManager?.noteInteraction()
    }

    // MARK: - Pattern Tester

    @ViewBuilder
    private func patternTester(_ approval: ApprovalCoordinator.PendingApproval) -> some View {
        let currentCmd = editedCommand.isEmpty
            ? (approval.payload.filePath ?? "")
            : editedCommand
        if !currentCmd.isEmpty && !sessionPattern.isEmpty {
            let result = PersistentRule.testPattern(sessionPattern, isRegex: isRegexMode, against: currentCmd)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Current:")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundColor(.secondary)
                    Text(currentCmd)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if let error = result.error {
                    Text(error)
                        .font(.body)
                        .foregroundColor(.red)
                } else {
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("Deny:")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                            resultBadge(
                                text: result.matches ? "BLOCKED" : "passes through",
                                color: result.matches ? .red : .green
                            )
                        }
                        HStack(spacing: 4) {
                            Text("Allow:")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                            resultBadge(
                                text: result.matches ? "ALLOWED" : "no effect",
                                color: result.matches ? .green : .gray
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func resultBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.body.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }

    /// Returns the edited command only if it differs from the original.
    private var cmdIfModified: String? {
        guard let original = sessionPanel.currentApproval?.payload.command else { return nil }
        return editedCommand != original ? editedCommand : nil
    }

    /// Returns updated toolInput if any editable fields were modified.
    private var updatedInputIfModified: [String: AnyCodable]? {
        guard let payload = sessionPanel.currentApproval?.payload else { return nil }
        let changes = editedFields.filter { key, value in
            value != (payload.toolInput[key]?.stringValue ?? "")
        }
        guard !changes.isEmpty else { return nil }
        var input = payload.toolInput
        for (key, value) in changes {
            input[key] = AnyCodable(value)
        }
        return input
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

// MARK: - NoteField sub-view

/// The note-to-Claude field, isolated into its own view so checkbox toggles
/// only re-render this slice — keeping the parent panel's action buttons
/// (Allow/Deny) stable. The checkbox is implemented as a `Button` styled with
/// SF Symbol icons rather than a `Toggle.checkbox`, because the latter's
/// underlying NSButton in floating utility panels can lose / shuffle key
/// responder status, eating the user's subsequent click on Deny. This combo
/// (state isolation + button-as-checkbox) fixes the wedge reproduced in the
/// pentest test case "tick checkbox then click Deny without typing".
private struct NoteField: View {
    @ObservedObject var state: NoteFieldState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note to Claude")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $state.text)
                .font(state.notePreviewActive
                      ? .system(.body, design: .monospaced).italic()
                      : .system(.body, design: .monospaced))
                .foregroundColor(state.notePreviewActive ? .secondary : .primary)
                .frame(minHeight: 36, maxHeight: 120)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.sendToClaude ? Color.green.opacity(0.6) : Color.secondary.opacity(0.3),
                                lineWidth: state.sendToClaude ? 1.5 : 1)
                )
                .onChange(of: state.text) { _ in
                    state.userEditedIfNeeded()
                }
            Button(action: { state.sendToClaude.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: state.sendToClaude ? "checkmark.square.fill" : "square")
                        .foregroundColor(state.sendToClaude ? .accentColor : .secondary)
                    Text("Send note to Claude (off by default — used for testing / explicit context)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("When checked, the note above is sent to Claude as additionalContext on Allow. Denies always include the typed note as the deny reason regardless of this checkbox.")
        }
    }
}
