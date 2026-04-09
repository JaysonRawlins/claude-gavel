import SwiftUI

/// Status bar at the top of the monitor window.
struct StatusView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(viewModel.autoApproveText, systemImage: "checkmark.shield")
                    .foregroundColor(viewModel.autoApproveText.contains("all") ? .green : .secondary)
                Spacer()
                Label(viewModel.uptimeText, systemImage: "clock")
                    .foregroundColor(.secondary)
            }

            HStack {
                Label(viewModel.sessionRulesText, systemImage: "list.bullet.rectangle")
                    .foregroundColor(.secondary)
                Spacer()
                Label(viewModel.statsText, systemImage: "chart.bar")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}
