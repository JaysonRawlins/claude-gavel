import AppKit
import SwiftUI

/// Hosting view whose controls respond to the first click even when gavel is not the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
