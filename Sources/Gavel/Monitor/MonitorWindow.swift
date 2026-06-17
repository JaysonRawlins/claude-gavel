import SwiftUI
import UniformTypeIdentifiers

/// The main monitor window showing the live feed, rules editor, regex tester, and cheat sheet.
struct MonitorWindow: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var isPinned: Bool = false
    @State private var isCompact: Bool = false
    @State private var savedFrame: NSRect?
    @State private var savedCompactOrigin: NSPoint?
    @State private var selectedTab: MonitorTab = .feed
    @State private var sessionFilter: String = ""
    @State private var hideTombstones: Bool = false

    enum MonitorTab {
        case feed, rules, sessions, context, tester, reference
    }

    private var isDevBuild: Bool { (Bundle.main.executablePath ?? "").contains("/.build/") }
    private var buildLabel: String { isDevBuild ? "Dev" : "v\(GAVEL_VERSION)" }

    var body: some View {
        Group {
            if isCompact {
                compactBar
            } else {
                fullBody
            }
        }
        .frame(minWidth: isCompact ? 320 : 600, minHeight: isCompact ? 28 : 400)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            collapseOnDeactivate()
        }
    }

    private func collapseOnDeactivate() {
        guard !isCompact, !isPinned else { return }
        guard let window = monitorWindow(), window.isVisible else { return }
        setCompact(true)
    }

    private func expandFromCompact() {
        NSApp.activate(ignoringOtherApps: true)
        setCompact(false)
        monitorWindow()?.makeKeyAndOrderFront(nil)
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.sessionManager.sessions.isEmpty ? Color.secondary : Color.green)
                .frame(width: 7, height: 7)
            Text(viewModel.compactSummary)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(buildLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(isDevBuild ? .orange : .secondary)
            Button(action: { expandFromCompact() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Expand the monitor")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { expandFromCompact() }
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            HStack {
                StatusView(viewModel: viewModel)
                Spacer()
                Text(buildLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isDevBuild ? .orange : .secondary)
                    .help(isDevBuild ? "Local dev build (.build/release) — not a released version" : "Released version \(GAVEL_VERSION)")
                Button(action: { setCompact(true) }) {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Collapse to a compact bar")
                Button(action: {
                    isPinned.toggle()
                    if let window = monitorWindow() {
                        window.level = isPinned ? .floating : .normal
                    }
                }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned
                      ? "Unpin — clicking another app collapses the monitor to the compact bar"
                      : "Pin the full window on top — stays expanded when you click another app")
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
    }

    private func monitorWindow() -> NSWindow? {
        NSApp.windows.first { $0.title.contains("Monitor") }
    }

    private func setCompact(_ compact: Bool) {
        let wasCompact = isCompact
        isCompact = compact
        guard let window = monitorWindow() else { return }
        if compact {
            savedFrame = window.frame
            window.level = .floating
            window.setFrame(compactRect(for: window), display: true, animate: true)
        } else {
            window.level = isPinned ? .floating : .normal
            if wasCompact {
                savedCompactOrigin = window.frame.origin
            }
            if let savedFrame {
                window.setFrame(savedFrame, display: true, animate: true)
            }
        }
        viewModel.noteInteraction()
    }

    private func compactRect(for window: NSWindow) -> NSRect {
        let size = NSSize(width: 420, height: 64)
        if let origin = savedCompactOrigin {
            let remembered = NSRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
                return remembered
            }
        }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        return NSRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height)
    }

    private var sessionControls: some View {
        VStack(spacing: 2) {
            let liveSessions = Array(viewModel.sessionManager.sessions.values)
                .sorted { $0.startedAt > $1.startedAt }
            let deadSessions = hideTombstones
                ? []
                : Array(viewModel.sessionManager.deadSessions.values)
                    .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            let allSessions = liveSessions + deadSessions
            let sessions = filterSessions(allSessions, query: sessionFilter)

            if allSessions.isEmpty {
                HStack {
                    Text("No active sessions")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else if sessions.isEmpty {
                HStack {
                    Text("No sessions match \"\(sessionFilter)\"")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.rowIdentity) { index, session in
                            SessionRow(
                                session: session,
                                viewModel: viewModel,
                                alternate: index.isMultiple(of: 2)
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
                .padding(.vertical, 2)

            HStack {
                Button("Clear Session Rules") {
                    viewModel.revokeAutoApprove()
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .help("Clears session-scoped patterns and disables auto-approve. Persistent rules (Rules tab) are not affected.")

                Button("Prompt All") {
                    viewModel.promptAllSessions()
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .help("One-click: clear auto on every session + reset defaults. Same as the menu bar action.")

                Button("Forget All Sleeping") {
                    viewModel.sessionManager.clearDeadSessions()
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .help("Remove every sleeping (tombstoned) session from the monitor.")

                Button("Forget Unnamed") {
                    viewModel.sessionManager.clearUnnamedDeadSessions()
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .help("Remove only the sleeping sessions that still have no name.")

                Button("Discover") {
                    viewModel.sessionManager.discoverRunningSessions()
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .help("Scan for Claude Code CLI processes that haven't fired a hook yet (e.g. started while gavel was down).")

                Button("Plans") {
                    EditorPreference.open(URL(fileURLWithPath:
                        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")))
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .help("Open ~/.claude/plans/ in your preferred editor.")

                Button("Skills") {
                    EditorPreference.open(URL(fileURLWithPath:
                        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills")))
                    viewModel.noteInteraction()
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .help("Open ~/.claude/skills/ in your preferred editor (resolves through your symlinks).")

                sessionFilterField

                activeOnlyToggle

                Spacer()

                inactivityPicker

                Toggle(isOn: Binding(
                    get: { viewModel.sessionManager.defaultAutoApprove },
                    set: { newVal in
                        viewModel.sessionManager.defaultAutoApprove = newVal
                        viewModel.sessionManager.saveDefaults()
                        viewModel.noteInteraction()
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

    private var activeOnlyToggle: some View {
        HStack(spacing: 4) {
            Text("Active only")
                .font(.caption)
                .lineLimit(1)
            Toggle("", isOn: $hideTombstones)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
        }
        .help("Hide sleeping sessions from the list")
    }

    private var sessionFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Filter sessions…", text: $sessionFilter)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 140)
            if !sessionFilter.isEmpty {
                Button(action: { sessionFilter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .help("Match against PID, session ID, working directory, or custom name")
    }

    /// Case-insensitive substring match across PID, session ID, cwd, label.
    private func filterSessions(_ sessions: [Session], query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        if q.hasPrefix("-tag:") {
            let token = String(q.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? sessions : sessions.filter { !$0.tags.matches(token: token) }
        }
        if q.hasPrefix("tag:") {
            let token = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? sessions : sessions.filter { $0.tags.matches(token: token) }
        }
        return sessions.filter { session in
            if String(session.pid).contains(q) { return true }
            if let sid = session.sessionId, sid.lowercased().contains(q) { return true }
            if let cwd = session.cwd, cwd.lowercased().contains(q) { return true }
            if session.label.lowercased().contains(q) { return true }
            return false
        }
    }

    private var inactivityPicker: some View {
        HStack(spacing: 4) {
            Text("Idle off")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { viewModel.sessionManager.inactivityTimeoutMinutes },
                set: { newVal in
                    viewModel.sessionManager.inactivityTimeoutMinutes = newVal
                    viewModel.sessionManager.saveDefaults()
                    viewModel.noteInteraction()
                }
            )) {
                Text("Off").tag(0)
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 90)
            .help("When gavel sees no user interaction for this long, auto-approval is revoked across all sessions.")
        }
    }

}

/// Observes Session directly so Pause/Resume labels and the per-tool-call flash repaint promptly.
private struct SessionRow: View {
    @ObservedObject var session: Session
    let viewModel: MonitorViewModel
    let alternate: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isAlive ? .green : .gray)
                .frame(width: 8, height: 8)

            if session.agent == .codex {
                Text("Codex")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }

            // verbatim avoids LocalizedStringKey's locale grouping (e.g. "12,345")
            Text(verbatim: "PID \(session.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
                .strikethrough(!session.isAlive)

            if let cwd = session.cwd {
                HStack(spacing: 4) {
                    Button {
                        EditorPreference.open(URL(fileURLWithPath: cwd))
                        viewModel.noteInteraction()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text(cwd.split(separator: "/").suffix(2).joined(separator: "/"))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(cwd) in your editor")

                    Button {
                        RepoBrowser.open(cwd: cwd)
                        viewModel.noteInteraction()
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Tower — staged, unstaged & untracked changes")
                }
            }

            SessionLabelField(session: session) { newVal in
                if let sid = session.sessionId {
                    viewModel.sessionManager.setLabel(newVal, for: sid)
                }
                viewModel.noteInteraction()
            }

            SessionTagBadges(tags: session.tags.snapshot)

            Spacer()

            if session.isAlive {
                actionCluster
            } else {
                tombstoneActionCluster
            }
        }
        .opacity(session.isAlive ? 1.0 : 0.55)
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(
            ZStack {
                rowBackground
                Color.yellow.opacity(session.lastActivityAt != nil ? 0.20 : 0)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(.easeOut(duration: 0.45), value: session.lastActivityAt)
    }

    @ViewBuilder
    private var actionCluster: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Sub")
                    .font(.caption)
                    .lineLimit(1)
                Toggle("", isOn: Binding(
                    get: { session.isSubAgentInheritEnabled },
                    set: { newVal in
                        session.isSubAgentInheritEnabled = newVal
                        let allSub = viewModel.sessionManager.sessions.values.allSatisfy { $0.isSubAgentInheritEnabled }
                        viewModel.sessionManager.defaultSubAgentInherit = allSub
                        viewModel.sessionManager.saveDefaults()
                        viewModel.sessionManager.saveActiveSessions()
                        viewModel.noteInteraction()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.cyan)
                .controlSize(.small)
            }
            .frame(width: 70, alignment: .leading)
            .help("Auto-approve sub-agent calls (deny rules still block)")

            HStack(spacing: 4) {
                Text("Auto")
                    .font(.caption)
                    .lineLimit(1)
                Toggle("", isOn: Binding(
                    get: { session.isAutoApproveEnabled },
                    set: { _ in
                        viewModel.toggleAutoApprove(for: session)
                        viewModel.noteInteraction()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
            }
            .frame(width: 76, alignment: .leading)

            HStack(spacing: 4) {
                Text("Phone")
                    .font(.caption)
                    .lineLimit(1)
                Toggle("", isOn: Binding(
                    get: { session.isRemoteApprovalEnabledUI },
                    set: { newVal in
                        let until = newVal ? Date().addingTimeInterval(Double(GavelConstants.remoteApprovalDefaultHours) * 3600) : nil
                        session.setRemoteApprovalEnabled(newVal, until: until)
                        viewModel.sessionManager.saveActiveSessions()
                        viewModel.noteInteraction()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.purple)
                .controlSize(.small)
            }
            .frame(width: 86, alignment: .leading)
            .disabled(viewModel.sessionManager.telegramChatId == nil)
            .help("Send this session's approvals to Telegram; either device can answer. Configure Telegram first.")

            planControl

            Button("Prompt") {
                viewModel.promptSession(session)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.yellow)
            .frame(width: 70)
            .help("Clear auto + sub-agent inherit + timed auto in one click. Next tool call will prompt.")

            Button(session.isPaused ? "Resume" : "Pause") {
                session.isPaused.toggle()
                let anyPaused = viewModel.sessionManager.sessions.values.contains { $0.isPaused }
                viewModel.sessionManager.defaultPaused = anyPaused
                viewModel.sessionManager.saveDefaults()
                viewModel.sessionManager.saveActiveSessions()
                viewModel.noteInteraction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(session.isPaused ? .green : .orange)
            .frame(width: 76)

            Button("Sleep") {
                if viewModel.sessionManager.isProcessAlive(pid: session.pid, cwd: session.cwd) {
                    kill(Int32(session.pid), SIGINT)
                } else {
                    viewModel.sessionManager.cleanupDeadSessions()
                }
                viewModel.noteInteraction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.indigo)
            .frame(width: 60)
            .help("SIGINT this Claude Code process so it saves to disk; resume later from the asleep row.")
        }
    }

    @ViewBuilder
    private var planControl: some View {
        Group {
            if session.isPlanPolicyEngaged {
                disengageButton
            } else {
                HStack(spacing: 4) {
                    planPickerMenu
                    engageButton
                }
            }
        }
        .frame(width: 110, alignment: .trailing)
    }

    private var engageButton: some View {
        Button("Plan") {
            if PlanPolicy.engage(session: session) {
                viewModel.sessionManager.saveActiveSessions()
                viewModel.noteInteraction()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(planPolicyDroppedReasonTint)
        .frame(width: 76)
        .disabled(session.lastPlanPath == nil)
        .help(planIdleHelp)
    }

    private var disengageButton: some View {
        Button(action: {
            PlanPolicy.disengage(session: session, reason: "manual")
            viewModel.sessionManager.saveActiveSessions()
            viewModel.noteInteraction()
        }) {
            HStack(spacing: 3) {
                Text("Plan")
                    .font(.caption.bold())
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.red)
        .frame(width: 76)
        .help(planActiveHelp)
    }

    private var planPickerMenu: some View {
        let plans = PlanPolicy.recentPlans()
        return Menu {
            if plans.isEmpty {
                Text("No plans found")
            } else {
                ForEach(plans) { plan in
                    Button {
                        armPlan(plan.path)
                    } label: {
                        if plan.path == session.lastPlanPath {
                            Label("\(plan.folder) · \(plan.filename)", systemImage: "checkmark")
                        } else {
                            Text("\(plan.folder) · \(plan.filename)")
                        }
                    }
                }
            }
            Divider()
            Button("Browse…") { browseForPlan() }
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .frame(width: 30)
        .help("Pick the plan to engage for this session (overrides auto-detect).")
    }

    private func armPlan(_ path: String) {
        session.lastPlanPath = path
        viewModel.sessionManager.saveActiveSessions()
        viewModel.noteInteraction()
    }

    private func browseForPlan() {
        let panel = NSOpenPanel()
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        panel.allowsMultipleSelection = false
        panel.title = "Select Plan to Engage"
        panel.message = "Pick a plan markdown file to engage for this session."
        panel.directoryURL = PlanPolicy.plansDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        armPlan(url.path)
    }

    private var planActiveHelp: String {
        let planName = (session.engagedPlanPath as NSString?)?.lastPathComponent ?? "unknown plan"
        return "Plan engaged — \(planName). Auto-approve is on for routine work; commit/infra still prompt and the plan's allow/deny apply. Click to drop."
    }

    private var planIdleHelp: String {
        if let reason = session.planPolicyDroppedReason {
            return "Plan dropped: \(reason). Click to re-engage with the current plan."
        }
        if let plan = session.lastPlanPath {
            let name = (plan as NSString).lastPathComponent
            return "Engage plan \(name) — turns on auto-approve, applies the plan's allow/deny overlay, keeps commit/infra prompting. Drops if the plan changes on disk."
        }
        return "No plan armed — pick one from the menu, or run /propose."
    }

    private var planPolicyDroppedReasonTint: Color {
        session.planPolicyDroppedReason != nil ? .orange : .red
    }

    /// Width must match actionCluster so live and dead rows align.
    @ViewBuilder
    private var tombstoneActionCluster: some View {
        HStack(spacing: 6) {
            if let ended = session.endedAt {
                Text("asleep \(Self.relativeTime(ended))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 222, alignment: .trailing)
            } else {
                Spacer().frame(width: 222)
            }

            Button("Resume") {
                copyResumeCommand()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.blue)
            .frame(width: 76)
            .disabled(session.sessionId == nil)
            .help(resumeHelpText)

            Button("Forget") {
                if let sid = session.sessionId {
                    viewModel.sessionManager.forgetTombstone(sessionId: sid)
                    viewModel.noteInteraction()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.gray)
            .frame(width: 56)
            .help("Remove this tombstone from the monitor.")
        }
    }

    private var resumeHelpText: String {
        guard let sid = session.sessionId else { return "No session ID — can't resume" }
        return "Copy `\(ResumeCommand.build(pid: session.pid, sessionId: sid, cwd: session.cwd, agent: session.agent))` to clipboard."
    }

    private func copyResumeCommand() {
        guard let sid = session.sessionId else { return }
        let cmd = ResumeCommand.build(pid: session.pid, sessionId: sid, cwd: session.cwd, agent: session.agent)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        viewModel.noteInteraction()
        GavelNotifications.notify(
            title: "Gavel — Resume command copied",
            body: "Paste in any terminal"
        )
    }

    private static func relativeTime(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    private var rowBackground: Color {
        alternate ? Color.secondary.opacity(0.06) : Color.clear
    }
}

private struct SessionTagBadges: View {
    let tags: [SessionTag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags.prefix(3), id: \.name) { tag in
                    Text(displayName(tag.name))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }
                if tags.count > 3 {
                    Text(verbatim: "+\(tags.count - 3)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .help(tags.dropFirst(3).map(\.name).joined(separator: ", "))
                }
            }
            .help(tags.map(\.name).joined(separator: ", "))
        }
    }

    private func displayName(_ name: String) -> String {
        name.hasPrefix("skill:") ? String(name.dropFirst(6)) : name
    }
}

/// Click-to-edit label control. Shows as a plain pill until clicked; only then
/// does it become a focusable TextField. This keeps the field from grabbing
/// first responder when the monitor opens and removes the always-on focus ring.
private struct SessionLabelField: View {
    @ObservedObject var session: Session
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Name…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 130)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onChange(of: focused) { isFocused in
                        if !isFocused && isEditing { commit() }
                    }
            } else {
                Button(action: beginEditing) {
                    Text(session.label.isEmpty ? "Name…" : session.label)
                        .font(.caption)
                        .italic(session.labelIsDerived)
                        .foregroundColor(labelColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 130, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .help(helpText)
    }

    private var labelColor: Color {
        if session.label.isEmpty { return .secondary }
        return session.labelIsDerived ? .secondary : .primary
    }

    private var helpText: String {
        if session.labelIsDerived {
            return "Auto-named from the first prompt — click to rename"
        }
        return session.sessionId.map { "Session ID: \($0)" } ?? "Click to name this session"
    }

    private func beginEditing() {
        draft = session.label
        isEditing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        session.labelIsDerived = false
        session.label = trimmed
        onCommit(trimmed)
        isEditing = false
    }

    private func cancel() {
        isEditing = false
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
                // Enable/disable toggle. Click flips the rule's `isDisabled`
                // and persists. Disabled rules render greyed-out to make the
                // off state visible at a glance — important when the user has
                // disabled a rule for testing and wants to remember to re-enable.
                Button(action: {
                    viewModel.setRuleDisabled(id: rule.id, isDisabled: !rule.isDisabled)
                    viewModel.noteInteraction()
                }) {
                    Image(systemName: rule.isDisabled ? "circle" : "checkmark.circle.fill")
                        .foregroundColor(rule.isDisabled ? .secondary : .green)
                }
                .buttonStyle(.plain)
                .help(rule.isDisabled
                      ? "Disabled — click to enable"
                      : "Enabled — click to temporarily disable (persists across restarts)")

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

                if rule.isDisabled {
                    Text("OFF")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.gray)
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
            .opacity(rule.isDisabled ? 0.5 : 1.0)

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
                    .sorted { $0.startedAt > $1.startedAt }

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

                Text(verbatim: "PID \(session.pid)")
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
                if !session.suppressedRuleIds.isEmpty {
                    Text("Suppressed: \(session.suppressedRuleIds.count)")
                        .foregroundColor(.indigo)
                }
                Text("Tainted: \(session.taintedPaths.count)")
                    .foregroundColor(.orange)
            }
            .font(.caption2)

            if !session.tags.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("Tags:").foregroundColor(.secondary)
                    Text(session.tags.snapshot.map(\.name).joined(separator: "   "))
                        .foregroundColor(.teal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
            }

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

            if !session.suppressedRuleIds.isEmpty {
                ForEach(Array(session.suppressedRuleIds), id: \.self) { ruleId in
                    HStack(spacing: 6) {
                        Text("SUPPRESSED")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.indigo)
                            .cornerRadius(3)

                        if let rule = viewModel.persistentRules.first(where: { $0.id == ruleId }) {
                            Text(rule.toolName)
                                .foregroundColor(.orange)
                            if rule.isRegex { Text("/").foregroundColor(.orange) }
                            Text(rule.pattern)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if rule.isRegex { Text("/").foregroundColor(.orange) }
                        } else {
                            Text("(deleted rule)")
                                .foregroundColor(.secondary)
                                .italic()
                        }

                        Spacer()

                        Button(action: {
                            viewModel.unsuppressRule(session: session, ruleId: ruleId)
                            viewModel.noteInteraction()
                        }) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop suppressing this rule — it will prompt again on next match")
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
