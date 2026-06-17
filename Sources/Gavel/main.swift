import AppKit
import Carbon.HIToolbox
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    let sessionManager = SessionManager()
    let approvalEngine = ApprovalEngine()
    let approvalCoordinator = ApprovalCoordinator()
    lazy var hookRouter: HookRouter = {
        approvalCoordinator.ruleStore = approvalEngine.ruleStore
        approvalCoordinator.sessionManager = sessionManager
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
    var configWatcher: ConfigWatcher?
    var remoteBridge: RemoteApprovalBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS smart dashes/quotes — gavel needs exact ASCII for patterns
        UserDefaults.standard.set(false, forKey: "NSAutomaticDashSubstitutionEnabled")
        UserDefaults.standard.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")
        UserDefaults.standard.set(false, forKey: "NSAutomaticTextCompletionEnabled")

        setupMainMenu()
        setupMenuBar()
        setupSocketServer()
        setupHookRouter()
        startRemoteBridge()
        ConfigIntegrity.shared.protect()
        setupConfigWatcher()
        reportLoadIntegrity()
        GavelNotifications.requestPermission()

        sessionManager.$defaultAutoApprove
            .receive(on: DispatchQueue.main)
            .sink { [weak self] autoApprove in
                self?.updateMenuBarIcon(autoApprove: autoApprove)
            }
            .store(in: &cancellables)

        registerGlobalHotKeys()

        NSApp.setActivationPolicy(.accessory) // Menu bar only, no dock icon
    }

    private func registerGlobalHotKeys() {
        // Cmd+Opt+Shift+P — system-wide "Prompt All Sessions" panic button.
        // Mirrors the menu item shortcut but fires even when another app is frontmost.
        let modifiers = UInt32(cmdKey | optionKey | shiftKey)
        GlobalHotKey.register(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers) { [weak self] in
            self?.viewModel.promptAllSessions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        configWatcher?.stop()
        ConfigIntegrity.shared.unprotect()
        remoteBridge?.stop()
        socketServer?.stop()
    }

    private func startRemoteBridge() {
        remoteBridge?.stop()
        let source = TelegramTokenResolver.resolve()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let token = source.load()
            DispatchQueue.main.async { self?.installBridge(token: token) }
        }
    }

    private func installBridge(token: String?) {
        guard let token else {
            remoteBridge = nil
            approvalCoordinator.remoteBridge = nil
            return
        }
        let transport = URLSessionTelegramTransport(token: token)
        let bridge = RemoteApprovalBridge(transport: transport, chatId: sessionManager.telegramChatId, redact: transport.redactToken)
        bridge.onPaired = { [weak self] chatId in
            DispatchQueue.main.async {
                self?.sessionManager.telegramChatId = chatId
                self?.sessionManager.saveDefaults()
                self?.viewModel.appendFeedEntry(.system("Telegram paired (chat \(chatId))", pid: Int(getpid()), at: Date()))
            }
        }
        bridge.onStatus = { [weak self] message in
            gavelLog("[telegram] \(message)")
            DispatchQueue.main.async {
                self?.viewModel.appendFeedEntry(.system("Telegram: \(message)", pid: Int(getpid()), at: Date()))
            }
        }
        approvalCoordinator.remoteBridge = bridge
        remoteBridge = bridge
        bridge.start()
    }

    @objc private func configureTelegram() {
        let alert = NSAlert()
        alert.messageText = "Configure Telegram Remote Approval"
        alert.informativeText = "Paste your bot token from @BotFather. After saving, open your bot in Telegram and send /start to pair this chat. Remote approval must also be enabled per session in the Sessions tab. Command text is sent to Telegram's servers; payloads containing detected credentials are withheld automatically."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "123456789:ABCdef..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let hasToken = TelegramCredentials.loadToken() != nil
        if hasToken { alert.addButton(withTitle: "Remove Token") }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            TelegramCredentials.storeToken(token)
            startRemoteBridge()
        case .alertThirdButtonReturn where hasToken:
            TelegramCredentials.clearToken()
            sessionManager.telegramChatId = nil
            sessionManager.saveDefaults()
            startRemoteBridge()
        default:
            break
        }
    }

    private func reportLoadIntegrity() {
        let message: String
        switch approvalEngine.ruleStore.lastLoadIntegrityStatus {
        case .intact, .established:
            return
        case .restoredFromBackup:
            message = "rules.json was modified while gavel was stopped — restored from verified backup"
        case .resetToDefaults:
            message = "rules.json failed integrity check on load with no valid backup — reset to built-in defaults"
        }
        gavelLog("ConfigBaseline: \(message)")
        viewModel.appendFeedEntry(.system("⚠️ \(message)", pid: Int(getpid()), at: Date()))
    }

    private func setupConfigWatcher() {
        let ruleStore = approvalEngine.ruleStore
        configWatcher = ConfigWatcher(
            path: ruleStore.filePath,
            isIntact: { ruleStore.onDiskMatchesMemory() },
            restore: { ruleStore.reassertOnDisk() },
            onTamper: { [weak self] in
                let message = "rules.json modified out-of-band — reverted from in-memory rules"
                gavelLog("ConfigWatcher: \(message)")
                DispatchQueue.main.async {
                    self?.viewModel.appendFeedEntry(.system("⚠️ \(message)", pid: Int(getpid()), at: Date()))
                }
            }
        )
        configWatcher?.start()
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
            button.toolTip = "Gavel — Claude Code Monitor"
        }
        updateMenuBarIcon(autoApprove: sessionManager.defaultAutoApprove)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Monitor", action: #selector(showMonitor), keyEquivalent: ""))
        let editorItem = NSMenuItem(title: "Editor Preference", action: nil, keyEquivalent: "")
        editorItem.submenu = buildEditorSubmenu()
        menu.addItem(editorItem)
        menu.addItem(NSMenuItem(title: "Configure Telegram…", action: #selector(configureTelegram), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Pause All Sessions", action: #selector(togglePauseAll), keyEquivalent: ""))
        let promptAllItem = NSMenuItem(title: "Prompt All Sessions", action: #selector(promptAll), keyEquivalent: "P")
        promptAllItem.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(promptAllItem)
        menu.addItem(NSMenuItem(title: "Clear Session Rules", action: #selector(revokeAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Restart Gavel", action: #selector(reloadBinary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Gavel", action: #selector(quit), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func updateMenuBarIcon(autoApprove: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = "gavel.fill"
        let fallback = "shield.checkered"

        if autoApprove {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Gavel — Auto-approve on")
                ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "Gavel — Auto-approve on")
            button.image = image?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Gavel")
                ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "Gavel")
            button.image = image
        }
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
            window.contentView = FirstMouseHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            monitorWindow = window
        }
        monitorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildEditorSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let editors = EditorPreference.availableEditors()
        let preferred = EditorPreference.preferredBundleID

        for editor in editors {
            let item = NSMenuItem(title: editor.name, action: #selector(selectPreferredEditor(_:)), keyEquivalent: "")
            item.representedObject = editor.bundleID
            item.target = self
            if editor.bundleID == preferred {
                item.state = .on
            }
            submenu.addItem(item)
        }

        if editors.isEmpty {
            submenu.addItem(NSMenuItem(title: "No editors found", action: nil, keyEquivalent: ""))
        }

        return submenu
    }

    @objc private func selectPreferredEditor(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        EditorPreference.preferredBundleID = bundleID

        if let editorItem = statusItem.menu?.items.first(where: { $0.title == "Editor Preference" }) {
            editorItem.submenu = buildEditorSubmenu()
        }
    }

    @objc private func togglePauseAll() {
        viewModel.togglePause()
    }

    @objc private func promptAll() {
        viewModel.promptAllSessions()
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
        } catch GavelError.daemonAlreadyRunning(let path) {
            // TOCTOU: a peer daemon came up between our top-level probe and
            // this bind. Refuse to clobber it.
            gavelLog("Refusing to start: another gavel daemon is already serving \(path) (TOCTOU)")
            FileHandle.standardError.write(Data("gavel: another daemon is already running on \(path)\n".utf8))
            exit(1)
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

        sessionManager.onLifecycle = { [weak self] message, pid, at in
            DispatchQueue.main.async {
                self?.viewModel.appendFeedEntry(.system(message, pid: pid, at: at))
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

// Argv handling — runs BEFORE any daemon setup. Without this, an unknown
// arg like `gavel --version` falls through to NSApplication.run() and
// silently launches a second daemon that fights the real one for the socket
// (split-brain). Diagnostic invocations should never bind the socket.
parseArgsOrExit(Array(CommandLine.arguments.dropFirst()))

// Ignore SIGPIPE — clients disconnect, we don't want to die
signal(SIGPIPE, SIG_IGN)

// Catch fatal signals
for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
    signal(sig) { signum in
        gavelLog("SIGNAL: \(signum)")
        exit(signum)
    }
}

// SIGTERM (launchd / `brew services stop`) and SIGINT (dev Ctrl-C) do NOT
// trigger applicationWillTerminate, so config would stay immutable after a
// graceful stop. Handle them via DispatchSource (runs off the signal context,
// so the lock + chflags in unprotect() are safe) to clear the flag before exit.
let signalQueue = DispatchQueue(label: "com.gavel.signals")
let terminationSignalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        gavelLog("SIGNAL: \(sig) — unprotecting config before exit")
        RemoteApprovalBridge.shared?.stop()
        ConfigIntegrity.shared.unprotect()
        exit(0)
    }
    source.resume()
    return source
}

gavelLog("Gavel starting")

// Single-instance guard: probe the socket BEFORE NSApplication.run() so a
// duplicate launch never shows a menu bar icon and never registers as a
// running daemon. SocketServer.start() also enforces this, but probing
// here keeps the foot-gun symptoms (split-brain, ghost menu bar) off the
// screen entirely.
let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/gavel/gavel.sock").path
if SocketServer.probeAlive(socketPath: socketPath) {
    gavelLog("Refusing to start: another gavel daemon is already serving \(socketPath)")
    FileHandle.standardError.write(Data("gavel: another daemon is already running on \(socketPath)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = GavelAppDelegate()
app.delegate = delegate
app.run()

// MARK: - Argv parsing

/// Returns normally only when the binary should proceed to daemon launch.
/// Calls `exit()` for `--version`/`--help` and any unknown argument, so the
/// process never reaches `NSApplication.run()` and never binds the socket.
func parseArgsOrExit(_ args: [String]) {
    if args.isEmpty { return }
    if args.count > 1 {
        FileHandle.standardError.write(Data("gavel: too many arguments (expected 0 or 1)\n".utf8))
        FileHandle.standardError.write(Data("Try 'gavel --help' for usage.\n".utf8))
        exit(2)
    }
    switch args[0] {
    case "--version", "-v":
        print("gavel \(GAVEL_VERSION)")
        exit(0)
    case "--help", "-h":
        print("""
        gavel — Claude Code session monitor and approval daemon

        Usage:
          gavel              Run as menu bar daemon (managed by LaunchAgent)
          gavel --version    Print version and exit
          gavel --help       Print this help and exit
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("gavel: unknown argument: \(args[0])\n".utf8))
        FileHandle.standardError.write(Data("Try 'gavel --help' for usage.\n".utf8))
        exit(2)
    }
}
