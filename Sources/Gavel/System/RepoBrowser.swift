import Foundation

/// Opens a repository's working copy in Git Tower for a pre-commit spot check —
/// staged, unstaged, and untracked changes in one view, with Kaleidoscope a
/// click away. Detached and best-effort: failures surface as a notification.
enum RepoBrowser {
    static func open(cwd: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["gittower", cwd]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        // The LaunchAgent inherits a minimal PATH; the gittower CLI lives here.
        var environment = ProcessInfo.processInfo.environment
        let toolPaths = "/usr/local/bin:/opt/homebrew/bin"
        environment["PATH"] = toolPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        task.environment = environment
        task.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            GavelNotifications.notify(
                title: "Gavel — Couldn't open Tower",
                body: "Is Git Tower installed and is this a git repo?\n\(cwd)"
            )
        }
        do {
            try task.run()
        } catch {
            GavelNotifications.notify(title: "Gavel — Couldn't open Tower", body: "gittower CLI not found")
        }
    }
}
