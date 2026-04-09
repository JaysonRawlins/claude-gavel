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

    /// Post a native macOS notification.
    static func notify(title: String, body: String, sound: Bool = true) {
        // osascript works universally — no bundle required
        let soundClause = sound ? #" sound name "Glass""# : ""
        let escaped_title = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escaped_body = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"display notification "\#(escaped_body)" with title "\#(escaped_title)"\#(soundClause)"#

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        // Fire and forget — don't wait
    }
}
