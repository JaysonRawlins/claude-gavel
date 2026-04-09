import SwiftUI

/// The main monitor window showing the live feed of all Claude Code sessions.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            StatusView(viewModel: viewModel)
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
            // Session rows with per-session auto-approve
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

            // Global controls
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
            // Session identity
            Circle()
                .fill(session.isAlive ? .green : .gray)
                .frame(width: 8, height: 8)

            Text("PID \(session.pid)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .leading)

            if let sid = session.sessionId {
                Text(String(sid.prefix(12)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let cwd = session.cwd {
                Text(cwd.split(separator: "/").suffix(2).joined(separator: "/"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

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
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(session.isPaused ? .green : .orange)
        }
    }
}
