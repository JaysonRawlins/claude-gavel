import AppKit
import UniformTypeIdentifiers

/// Discovers installed editors and remembers the user's choice.
enum EditorPreference {
    private static let key = "preferredEditorBundleID"

    static var preferredBundleID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// All apps that can open .md files, sorted with common editors first.
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

    /// Open a file in the user's preferred editor, falling back to system default.
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
