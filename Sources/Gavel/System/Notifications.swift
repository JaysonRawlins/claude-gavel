import Foundation

/// Native macOS notifications — UNUserNotificationCenter when running inside a .app bundle; osascript fallback when running as a bare executable from .build/release/.
struct GavelNotifications {
    private static var hasBundleIdentifier: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestPermission() {
        guard hasBundleIdentifier else { return }
        // Lazy/dynamic dispatch — avoids a crash on bare-binary runs where UNUserNotificationCenter is unavailable.

        if let center = NSClassFromString("UNUserNotificationCenter") as? NSObject.Type,
           let obj = center.perform(NSSelectorFromString("currentNotificationCenter"))?.takeUnretainedValue() {
            let sel = NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")

            _ = (obj as AnyObject).perform(sel, with: 6 as NSNumber, with: { (_: Bool, _: Error?) in } as @convention(block) (Bool, Error?) -> Void)
        }
    }

    /// Post a notification via osascript — works whether or not we have a bundle, so it's the universal path.
    static func notify(title: String, body: String, sound: Bool = true) {
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
    }
}
