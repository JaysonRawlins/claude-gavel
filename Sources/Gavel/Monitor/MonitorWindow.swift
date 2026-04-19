import SwiftUI

/// The main monitor window showing the live feed, rules editor, regex tester, and cheat sheet.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var isPinned: Bool = false
    @State private var selectedTab: MonitorTab = .feed

    enum MonitorTab {
        case feed, rules, sessions, context, tester, reference
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
                Text("Sessions").tag(MonitorTab.sessions)
                Text("Context").tag(MonitorTab.context)
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
            case .sessions:
                SessionRulesView(viewModel: viewModel)
            case .context:
                SessionContextView()
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

                Toggle(isOn: Binding(
                    get: { viewModel.sessionManager.defaultAutoApprove },
                    set: { newVal in
                        viewModel.sessionManager.defaultAutoApprove = newVal
                        viewModel.sessionManager.saveDefaults()
                    }
                )) {
                    Text("Default Auto")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
                .help("New sessions start with auto-approve enabled. Deny rules, prompt rules, and sensitive paths still force dialogs.")
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

            Button("Kill") {
                kill(Int32(session.pid), SIGINT)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .help("Send SIGINT to this session's Claude Code process")
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
    @State private var searchText: String = ""
    @State private var editingRuleId: UUID?
    @State private var editPattern: String = ""
    @State private var editIsRegex: Bool = false
    @State private var editVerdict: DecisionVerdict = .block
    @State private var editExplanation: String = ""

    private let toolOptions = ["*", "Bash", "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep", "Agent"]

    /// Filter rules by search text — matches against tool name, pattern, explanation, and verdict.
    private func matchesSearch(_ rule: PersistentRule) -> Bool {
        guard !searchText.isEmpty else { return true }
        let query = searchText.lowercased()
        return rule.toolName.lowercased().contains(query)
            || rule.pattern.lowercased().contains(query)
            || (rule.explanation ?? "").lowercased().contains(query)
            || verdictLabel(rule.verdict).lowercased().contains(query)
            || (rule.builtIn && "default".contains(query))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Add rule form
            addRuleForm
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Search + Import/Export bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search rules…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

                importExportBar
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Existing rules list (user rules first, built-in defaults at bottom)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let userRules = viewModel.persistentRules.filter { !$0.builtIn && matchesSearch($0) }
                    let builtInRules = viewModel.persistentRules.filter { $0.builtIn && matchesSearch($0) }

                    if userRules.isEmpty && builtInRules.isEmpty {
                        if searchText.isEmpty {
                            Text("No rules yet. Add one above or use the approval panel.")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            Text("No rules matching \"\(searchText)\"")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    } else {
                        ForEach(userRules) { rule in
                            ruleRow(rule)
                        }

                        if !builtInRules.isEmpty {
                            if !userRules.isEmpty { Divider().padding(.vertical, 4) }
                            Text("Built-in Defaults")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                                .padding(.leading, 8)
                            ForEach(builtInRules) { rule in
                                ruleRow(rule)
                            }
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
                        .onChange(of: newPattern) { pattern in
                            if !newIsRegex && PatternCompiler.looksLikeRegex(pattern) {
                                newIsRegex = true
                            }
                        }
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
        VStack(spacing: 0) {
            // Display row
            HStack(spacing: 6) {
                Text(verdictLabel(rule.verdict))
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(verdictColor(rule.verdict))
                    .cornerRadius(4)

                Text(rule.isRegex ? "REGEX" : "GLOB")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(rule.isRegex ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5))
                    .cornerRadius(3)

                if rule.builtIn {
                    Text("DEFAULT")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.6))
                        .cornerRadius(3)
                }

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

                Button(action: { startEditing(rule) }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit this rule")

                Button(action: { viewModel.deleteRule(id: rule.id) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this rule")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Inline edit form (shown when editing this rule)
            if editingRuleId == rule.id {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            if editIsRegex {
                                Text("/").font(.system(.caption, design: .monospaced)).foregroundColor(.orange)
                            }
                            TextField("pattern", text: $editPattern)
                                .font(.system(.caption, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: editPattern) { pattern in
                                    if !editIsRegex && PatternCompiler.looksLikeRegex(pattern) {
                                        editIsRegex = true
                                    }
                                }
                            if editIsRegex {
                                Text("/").font(.system(.caption, design: .monospaced)).foregroundColor(.orange)
                            }
                        }

                        Toggle("Regex", isOn: $editIsRegex)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(.orange)
                    }

                    HStack(spacing: 8) {
                        Picker("", selection: $editVerdict) {
                            Text("Deny").tag(DecisionVerdict.block)
                            Text("Allow").tag(DecisionVerdict.allow)
                            Text("Ask").tag(DecisionVerdict.prompt)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)

                        if editVerdict == .block || editVerdict == .prompt {
                            TextField("Explanation (optional)", text: $editExplanation)
                                .font(.system(.caption, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                        }

                        Spacer()

                        Button("Cancel") { editingRuleId = nil }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("Save") { saveEdit(rule) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.blue)
                            .disabled(editPattern.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }

    private func startEditing(_ rule: PersistentRule) {
        editingRuleId = rule.id
        editPattern = rule.pattern
        editIsRegex = rule.isRegex
        editVerdict = rule.verdict
        editExplanation = rule.explanation ?? ""
    }

    private func saveEdit(_ rule: PersistentRule) {
        viewModel.updateRule(
            id: rule.id,
            pattern: editPattern,
            isRegex: editIsRegex,
            verdict: editVerdict,
            explanation: editExplanation.isEmpty ? nil : editExplanation
        )
        editingRuleId = nil
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

// MARK: - Session Rules View

struct SessionRulesView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let sessions = Array(viewModel.sessionManager.sessions.values)
                    .sorted { $0.pid < $1.pid }

                if sessions.isEmpty {
                    Text("No active sessions.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(sessions, id: \.pid) { session in
                        sessionSection(session)
                    }
                }
            }
            .padding(8)
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func sessionSection(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Session header
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isAlive ? .green : .gray)
                    .frame(width: 8, height: 8)

                Text("PID \(session.pid)")
                    .font(.system(.body, design: .monospaced).bold())

                if let cwd = session.cwd {
                    Text(cwd.split(separator: "/").suffix(3).joined(separator: "/"))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    if session.isAutoApproveEnabled {
                        badge("AUTO", color: .green)
                    }
                    if session.isSubAgentInheritEnabled {
                        badge("SUB", color: .cyan)
                    }
                    if session.isPaused {
                        badge("PAUSED", color: .orange)
                    }
                }
            }

            // Session info
            HStack(spacing: 16) {
                Text("Tools: \(session.toolCallCount)")
                    .foregroundColor(.secondary)
                Text("Allow: \(session.allowCount)")
                    .foregroundColor(.green)
                Text("Block: \(session.blockCount)")
                    .foregroundColor(.red)
                Text("Rules: \(session.sessionRules.count)")
                    .foregroundColor(.purple)
                Text("Tainted: \(session.taintedPaths.count)")
                    .foregroundColor(.orange)
            }
            .font(.caption2)

            // Session rules
            if session.sessionRules.isEmpty {
                Text("No session rules")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.leading, 16)
            } else {
                ForEach(session.sessionRules) { rule in
                    HStack(spacing: 6) {
                        Text(rule.verdict == .block ? "DENY" : "ALLOW")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(rule.verdict == .block ? Color.pink : Color.purple)
                            .cornerRadius(3)

                        Text(rule.toolName)
                            .foregroundColor(.orange)

                        Text(rule.pattern)
                            .foregroundColor(.primary)

                        if let explanation = rule.explanation {
                            Text("— \(explanation)")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button(action: {
                            session.sessionRules.removeAll { $0.id == rule.id }
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 16)
                }
            }

            // Tainted paths (if any)
            if !session.taintedPaths.isEmpty {
                Text("Tainted paths:")
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
                    .padding(.leading, 16)
                    .padding(.top, 2)

                ForEach(Array(session.taintedPaths.sorted()), id: \.self) { path in
                    Text(path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color)
            .cornerRadius(3)
    }
}
