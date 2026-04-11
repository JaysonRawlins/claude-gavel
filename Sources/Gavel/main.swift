import AppKit
import SwiftUI

/// Gavel — Native macOS daemon for Claude Code session monitoring and approval.
///
/// Runs as a menu bar app. Listens on a Unix socket for hook events,
/// evaluates approval rules, and displays a live activity monitor.
/// In interactive mode, pops up an approval dialog for each tool call.

// MARK: - App Delegate

class GavelAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitorWindow: NSWindow?

    let sessionManager = SessionManager()
    let approvalEngine = ApprovalEngine()
    let approvalCoordinator = ApprovalCoordinator()
    lazy var hookRouter: HookRouter = {
        approvalCoordinator.ruleStore = approvalEngine.ruleStore
        return HookRouter(
            sessionManager: sessionManager,
            approvalEngine: approvalEngine,
            approvalCoordinator: approvalCoordinator
        )
    }()
    lazy var viewModel = MonitorViewModel(
        sessionManager: sessionManager,
        approvalCoordinator: approvalCoordinator
    )
    var socketServer: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS smart dashes/quotes — gavel needs exact ASCII for patterns
        UserDefaults.standard.set(false, forKey: "NSAutomaticDashSubstitutionEnabled")
        UserDefaults.standard.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")
        UserDefaults.standard.set(false, forKey: "NSAutomaticTextCompletionEnabled")

        setupMainMenu()
        setupMenuBar()
        setupSocketServer()
        setupHookRouter()
        GavelNotifications.requestPermission()

        NSApp.setActivationPolicy(.accessory) // Menu bar only, no dock icon
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
    }

    // MARK: - Main Menu (needed for Cmd+V/C/X/A in text fields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Gavel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — enables standard text editing shortcuts
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gavel.fill", accessibilityDescription: "Gavel")
                ?? NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "Gavel")
            button.toolTip = "Gavel — Claude Code Monitor"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Monitor", action: #selector(showMonitor), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle Auto-Approve", action: #selector(toggleAutoApprove), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pause All Sessions", action: #selector(togglePauseAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Session Rules", action: #selector(revokeAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reload Binary", action: #selector(reloadBinary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Gavel", action: #selector(quit), keyEquivalent: ""))
        statusItem.menu = menu
    }

    @objc private func showMonitor() {
        if monitorWindow == nil {
            let contentView = MonitorWindow(viewModel: viewModel)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gavel — Claude Code Monitor"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            monitorWindow = window
        }
        monitorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAutoApprove() {
        // Toggle for the first active session (use monitor for per-session control)
        guard let session = sessionManager.sessions.values.first else { return }
        viewModel.toggleAutoApprove(for: session)
    }

    @objc private func togglePauseAll() {
        viewModel.togglePause()
    }

    @objc private func revokeAll() {
        viewModel.revokeAutoApprove()
    }

    @objc private func reloadBinary() {
        gavelLog("Reload requested — exiting for LaunchAgent restart")
        socketServer?.stop()
        // Clean exit — LaunchAgent's KeepAlive restarts us with the updated binary
        exit(0)
    }

    @objc private func quit() {
        socketServer?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Socket Server

    private func setupSocketServer() {
        let socketDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/gavel")
        try? FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)

        let socketPath = socketDir.appendingPathComponent("gavel.sock").path
        socketServer = SocketServer(socketPath: socketPath)

        do {
            try socketServer?.start()
            print("Gavel listening on \(socketPath)")
        } catch {
            print("Failed to start socket server: \(error)")
        }
    }

    private func setupHookRouter() {
        hookRouter.onFeedEvent = { [weak self] entry in
            self?.viewModel.appendFeedEntry(entry)

            if case .stop = entry {
                GavelNotifications.notify(title: "Claude Code", body: "Ready for input")
            }
        }

        socketServer?.onEvent = { [weak self] data, respond in
            self?.hookRouter.handle(data: data, respond: respond)
        }
    }
}

// MARK: - Launch

// Crash logging — write last words before dying
let logPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/gavel/gavel.log").path

func gavelLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

// Catch uncaught exceptions
NSSetUncaughtExceptionHandler { exception in
    gavelLog("CRASH: \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
    gavelLog("STACK: \(exception.callStackSymbols.prefix(10).joined(separator: "\n  "))")
}

// Ignore SIGPIPE — clients disconnect, we don't want to die
signal(SIGPIPE, SIG_IGN)

// Catch fatal signals
for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
    signal(sig) { signum in
        gavelLog("SIGNAL: \(signum)")
        exit(signum)
    }
}

gavelLog("Gavel starting")

let app = NSApplication.shared
let delegate = GavelAppDelegate()
app.delegate = delegate
app.run()
