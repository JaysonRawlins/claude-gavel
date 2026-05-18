import AppKit
import UniformTypeIdentifiers

/// Discovers installed editors that can open `.md` and remembers the user's pick (UserDefaults key `preferredEditorBundleID`).
enum EditorPreference {
    private static let key = "preferredEditorBundleID"

    static var preferredBundleID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Editors that claim `.md` support, sorted with common editors (Zed/VSCode/Sublime/JetBrains/Xcode) first.
    static func availableEditors() -> [(name: String, bundleID: String, url: URL)] {
        let mdType = UTType(filenameExtension: "md") ?? .plainText
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: mdType)

        let priorityBundles = [
            "dev.zed.Zed",
            "com.microsoft.VSCode",
            "com.sublimetext.4",
            "com.sublimetext.3",
            "com.jetbrains.intellij",
            "com.apple.dt.Xcode",
            "com.apple.TextEdit",
        ]

        var editors: [(name: String, bundleID: String, url: URL)] = []
        for url in appURLs {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
            editors.append((name: name, bundleID: bundleID, url: url))
        }

        return editors.sorted { a, b in
            let ai = priorityBundles.firstIndex(of: a.bundleID) ?? Int.max
            let bi = priorityBundles.firstIndex(of: b.bundleID) ?? Int.max
            if ai != bi { return ai < bi }
            return a.name < b.name
        }
    }

    /// Open `url` in the user's preferred editor; falls back to the system default if the preference isn't set or the app is missing.
    static func open(_ url: URL) {
        if let bundleID = preferredBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
