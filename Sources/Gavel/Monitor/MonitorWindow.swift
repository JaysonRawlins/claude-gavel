import SwiftUI

/// The main monitor window showing the live feed of all Claude Code sessions.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var isPinned: Bool = false

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

            // Event feed
            FeedView(entries: viewModel.feedEntries)

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
                Button("Revoke All Rules") {
                    viewModel.revokeAutoApprove()
                }
                .buttonStyle(.bordered)
                .tint(.purple)

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

            // Sub-agent inheritance toggle
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

            // Per-session auto-approve toggle
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
