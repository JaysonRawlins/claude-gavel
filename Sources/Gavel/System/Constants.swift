import Foundation

/// Shared constants for the gavel daemon.
enum GavelConstants {
    /// 24 hours — long enough for user to return from AFK, short enough to not hang forever.
    static let approvalTimeoutSeconds: TimeInterval = 86400

    static let maxFeedEntries = 2000

    static let socketListenBacklog: Int32 = 32

    static let socketBufferSize = 64 * 1024

    /// 30s, not 2s — bound is per `read()`, not per conversation. Burst load (5 parallel `gavel-hook` subprocesses) can deschedule a hook for hundreds of ms between connect() and write(); a 2s cap timed out one in the burst, Claude then SIGTERM'd siblings as parallel-call cancellation.
    static let socketReadTimeoutSeconds: Int = 30

    static let statsUpdateInterval: TimeInterval = 2.0

    static let sessionCleanupInterval: TimeInterval = 5.0

    /// Below this length, content can't plausibly contain both file I/O and network code — skip the exfil-wrapper scan.
    static let minContentScanLength = 50

    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 480

    /// Tools that are user-interaction (not tool execution) — pass through to Claude's built-in UI without an approval round-trip.
    static let userInteractionTools = ["AskUserQuestion", "ExitPlanMode"]

    /// Temp-like prefixes where polyglot exfil content scanning applies. Files outside these paths skip the scan.
    static let tempDirectoryPrefixes = ["/tmp/", "/var/tmp/", "/private/tmp/", "/var/folders/"]
}
