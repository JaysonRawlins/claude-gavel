import SwiftUI

/// History viewer for a session: renders its transcript so an unrecognized
/// (often sleeping) row can be named or forgotten without resuming it — resuming
/// would respawn a dead session just to read it. Rename + Forget live here so the
/// whole name-or-ditch decision happens in one place.
struct TranscriptView: View {
    @ObservedObject var session: Session
    let viewModel: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [TranscriptMessage] = []
    @State private var loaded = false
    @State private var draftName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptBody
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Name this session", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            Button("Rename", action: rename)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if messages.isEmpty {
            VStack(spacing: 6) {
                Text("No readable transcript")
                Text("The transcript is gone or held only tool activity — nothing to read.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { TranscriptBubble(message: $0) }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !session.isAlive, session.sessionId != nil {
                Button("Forget", role: .destructive, action: forget)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func load() {
        draftName = session.label
        guard let sid = session.sessionId, let cwd = session.cwd else {
            loaded = true
            return
        }
        // Parsing reads the whole .jsonl off disk; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = TranscriptReader.messages(cwd: cwd, sessionId: sid)
            DispatchQueue.main.async {
                messages = parsed
                loaded = true
            }
        }
    }

    private func rename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.sessionManager.updateLabel(trimmed, on: session)
        viewModel.noteInteraction()
    }

    private func forget() {
        guard let sid = session.sessionId else { return }
        viewModel.sessionManager.forgetTombstone(sessionId: sid)
        viewModel.noteInteraction()
        dismiss()
    }
}

private struct TranscriptBubble: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.role == .user ? "👤 You" : "🤖 Claude")
                .font(.caption).bold()
                .foregroundColor(message.role == .user ? .blue : .purple)
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(message.role == .user ? Color.blue.opacity(0.08) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
