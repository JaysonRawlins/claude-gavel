import SwiftUI

/// The main monitor window showing the live feed, rules editor, regex tester, and cheat sheet.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var isPinned: Bool = false
    @State private var selectedTab: MonitorTab = .feed

    enum MonitorTab {
        case feed, rules, tester, reference
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar with pin toggle
            HStack {
                StatusView(viewModel: viewModel)
                Spacer()
                Button(action: {
                    isPinned.toggle()
                    if let window = NSApp.windows.first(where: { $0.title.contains("Monitor") }) {
                        window.level = isPinned ? .floating : .normal
                    }
                }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin window" : "Pin window on top")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Feed").tag(MonitorTab.feed)
                Text("Rules (\(viewModel.ruleCount))").tag(MonitorTab.rules)
                Text("Tester").tag(MonitorTab.tester)
                Text("Reference").tag(MonitorTab.reference)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Content
            switch selectedTab {
            case .feed:
                FeedView(entries: viewModel.feedEntries)
            case .rules:
                RulesView(viewModel: viewModel)
            case .tester:
                RegexTesterView(viewModel: viewModel)
            case .reference:
                RegexCheatSheetView()
            }

            Divider()

            // Per-session controls
            sessionControls
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var sessionControls: some View {
        VStack(spacing: 4) {
            let sessions = Array(viewModel.sessionManager.sessions.values)
                .sorted { $0.pid < $1.pid }

            if sessions.isEmpty {
                HStack {
                    Text("No active sessions")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                ForEach(sessions, id: \.pid) { session in
                    sessionRow(session)
                }
            }

            Divider()
                .padding(.vertical, 2)

            HStack {
                Button("Clear Session Rules") {
                    viewModel.revokeAutoApprove()
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .help("Clears session-scoped patterns and disables auto-approve. Persistent rules (Rules tab) are not affected.")

                Spacer()

                Button("Kill Session") {
                    viewModel.killSession()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isAlive ? .green : .gray)
                .frame(width: 8, height: 8)

            Text("PID \(session.pid)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .leading)

            if let cwd = session.cwd {
                Text(cwd.split(separator: "/").suffix(2).joined(separator: "/"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { session.isSubAgentInheritEnabled },
                set: { newVal in
                    session.isSubAgentInheritEnabled = newVal
                    let allSub = viewModel.sessionManager.sessions.values.allSatisfy { $0.isSubAgentInheritEnabled }
                    viewModel.sessionManager.defaultSubAgentInherit = allSub
                    viewModel.sessionManager.saveDefaults()
                }
            )) {
                Text("Sub")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .tint(.cyan)
            .controlSize(.small)
            .help("Auto-approve sub-agent calls (deny rules still block)")

            Toggle(isOn: Binding(
                get: { session.isAutoApproveEnabled },
                set: { _ in viewModel.toggleAutoApprove(for: session) }
            )) {
                Text("Auto")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .controlSize(.small)

            Button(session.isPaused ? "Resume" : "Pause") {
                session.isPaused.toggle()
                let anyPaused = viewModel.sessionManager.sessions.values.contains { $0.isPaused }
                viewModel.sessionManager.defaultPaused = anyPaused
                viewModel.sessionManager.saveDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(session.isPaused ? .green : .orange)
        }
    }
}

// MARK: - Rules View (enhanced with add form + import/export)

struct RulesView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var newPattern: String = ""
    @State private var newToolName: String = "*"
    @State private var newIsRegex: Bool = false
    @State private var newVerdict: DecisionVerdict = .block
    @State private var newExplanation: String = ""
    @State private var importError: String?

    private let toolOptions = ["*", "Bash", "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep", "Agent"]

    var body: some View {
        VStack(spacing: 0) {
            // Add rule form
            addRuleForm
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Import/Export bar
            importExportBar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Existing rules list
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if viewModel.persistentRules.isEmpty {
                        Text("No rules yet. Add one above or use the approval panel.")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(viewModel.persistentRules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                .padding(8)
            }
            .font(.system(.caption, design: .monospaced))
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Add Rule Form

    private var addRuleForm: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Tool picker
                Picker("", selection: $newToolName) {
                    ForEach(toolOptions, id: \.self) { tool in
                        Text(tool).tag(tool)
                    }
                }
                .frame(width: 100)

                Text(":")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.secondary)

                // Pattern input
                HStack(spacing: 2) {
                    if newIsRegex {
                        Text("/").font(.system(.body, design: .monospaced)).foregroundColor(.orange)
                    }
                    TextField(newIsRegex ? "regex pattern" : "glob pattern (* = wildcard)", text: $newPattern)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    if newIsRegex {
                        Text("/").font(.system(.body, design: .monospaced)).foregroundColor(.orange)
                    }
                }

                Toggle("Regex", isOn: $newIsRegex)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.orange)
            }

            HStack(spacing: 8) {
                // Verdict picker
                Picker("", selection: $newVerdict) {
                    Text("Always Deny").tag(DecisionVerdict.block)
                    Text("Always Allow").tag(DecisionVerdict.allow)
                    Text("Always Ask").tag(DecisionVerdict.prompt)
                }
                .pickerStyle(.segmented)

                Button(action: addRule) {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(verdictColor(newVerdict))
                .disabled(newPattern.isEmpty)
            }

            // Explanation field for deny rules — Claude sees this when blocked
            if newVerdict == .block {
                TextEditor(text: $newExplanation)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 54)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        Group {
                            if newExplanation.isEmpty {
                                Text("Explanation for Claude — shown when this rule blocks a tool call")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.leading, 8)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        },
                        alignment: .topLeading
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    private func addRule() {
        guard !newPattern.isEmpty else { return }
        let sanitized = ApprovalCoordinator.sanitizeDashes(newPattern)
        let explText = (newVerdict == .block && !newExplanation.isEmpty) ? newExplanation : nil
        let rule = PersistentRule(
            toolName: newToolName,
            pattern: sanitized,
            isRegex: newIsRegex,
            verdict: newVerdict,
            explanation: explText
        )
        viewModel.addRule(rule)
        newPattern = ""
        newExplanation = ""
    }

    // MARK: - Import/Export

    private var importExportBar: some View {
        HStack(spacing: 8) {
            Button(action: exportRules) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: importRules) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(viewModel.ruleCount) rules")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "gavel-rules.json"
        panel.title = "Export Gavel Rules"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try viewModel.exportRules(to: url)
            importError = nil
        } catch {
            importError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Gavel Rules"
        panel.message = "Imported rules will be added to your existing rules."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try viewModel.importRules(from: url)
            importError = nil
            if count == 0 {
                importError = "No valid rules found in file"
            }
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Rule Row

    private func ruleRow(_ rule: PersistentRule) -> some View {
        HStack(spacing: 6) {
            Text(verdictLabel(rule.verdict))
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(verdictColor(rule.verdict))
                .cornerRadius(4)

            Text(rule.toolName)
                .foregroundColor(.orange)
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    if rule.isRegex {
                        Text("/").foregroundColor(.orange)
                    }
                    Text(rule.pattern)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if rule.isRegex {
                        Text("/").foregroundColor(.orange)
                    }
                }

                if let explanation = rule.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: {
                viewModel.deleteRule(id: rule.id)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete this rule")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }

    // MARK: - Helpers

    private func verdictLabel(_ verdict: DecisionVerdict) -> String {
        switch verdict {
        case .block: return "DENY"
        case .allow: return "ALLOW"
        case .prompt: return "ASK"
        }
    }

    private func verdictColor(_ verdict: DecisionVerdict) -> Color {
        switch verdict {
        case .block: return .red
        case .allow: return .green
        case .prompt: return .yellow
        }
    }
}
