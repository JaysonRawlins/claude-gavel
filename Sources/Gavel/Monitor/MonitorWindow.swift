import SwiftUI

/// The main monitor window showing the live feed and rules editor.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var isPinned: Bool = false
    @State private var selectedTab: MonitorTab = .feed

    enum MonitorTab {
        case feed, rules
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar with pin toggle
            HStack {
                StatusView(viewModel: viewModel)
                Spacer()
                Button(action: { [vm = viewModel] in
                    isPinned.toggle()
                    vm.setPinned(isPinned)
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

// MARK: - Rules View

struct RulesView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.persistentRules.isEmpty {
                    Text("No persistent rules. Use the approval panel to add Always Deny / Always Allow rules.")
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

    private func ruleRow(_ rule: PersistentRule) -> some View {
        HStack(spacing: 6) {
            Text(rule.verdict == .block ? "DENY" : "ALLOW")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(rule.verdict == .block ? Color.red : Color.green)
                .cornerRadius(4)

            Text(rule.toolName)
                .foregroundColor(.orange)
                .frame(width: 50, alignment: .leading)

            HStack(spacing: 2) {
                if rule.isRegex {
                    Text("/")
                        .foregroundColor(.orange)
                }
                Text(rule.pattern)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if rule.isRegex {
                    Text("/")
                        .foregroundColor(.orange)
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
}
