import Foundation

/// Native macOS notification support.
///
/// UNUserNotificationCenter requires a proper app bundle with a bundle identifier.
/// When running as a bare executable (e.g. from .build/release/), we fall back
/// to osascript which works without a bundle.
struct GavelNotifications {

    /// Whether we're running inside a proper .app bundle.
    private static var hasBundleIdentifier: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestPermission() {
        guard hasBundleIdentifier else { return }
        // Lazy import to avoid crash when no bundle exists
        if let center = NSClassFromString("UNUserNotificationCenter") as? NSObject.Type,
           let obj = center.perform(NSSelectorFromString("currentNotificationCenter"))?.takeUnretainedValue() {
            let sel = NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")
            // Best effort — if this fails, osascript fallback still works
            _ = (obj as AnyObject).perform(sel, with: 6 as NSNumber, with: { (_: Bool, _: Error?) in } as @convention(block) (Bool, Error?) -> Void)
        }
    }

    /// Post a native macOS notification. When `critical` is true, uses a modal
    /// `display dialog` that persists until the user dismisses it — for events
    /// the user must not miss (e.g., secret leaks). Otherwise uses the standard
    /// banner-style `display notification`.
    static func notify(title: String, body: String, sound: Bool = true, critical: Bool = false) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if critical {
            script = #"display dialog "\#(escapedBody)" with title "\#(escapedTitle)" buttons {"OK"} default button "OK" with icon caution"#
        } else {
            let soundClause = sound ? #" sound name "Glass""# : ""
            script = #"display notification "\#(escapedBody)" with title "\#(escapedTitle)"\#(soundClause)"#
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}
