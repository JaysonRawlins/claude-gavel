import Foundation

/// Shared constants used across the gavel daemon.
enum GavelConstants {
    /// 24 hours in seconds — effectively no timeout for interactive approval.
    /// Long enough for user to return from AFK, short enough to not hang forever.
    static let approvalTimeoutSeconds: TimeInterval = 86400

    /// Maximum feed entries before oldest are dropped to prevent unbounded memory growth.
    static let maxFeedEntries = 2000

    /// Socket listen backlog (max pending connections before OS drops them).
    static let socketListenBacklog: Int32 = 32

    /// Socket read buffer size (64KB chunks).
    static let socketBufferSize = 64 * 1024

    /// Socket read timeout in seconds.
    static let socketReadTimeoutSeconds: Int = 2

    /// Stats update interval in seconds.
    static let statsUpdateInterval: TimeInterval = 2.0

    /// Session cleanup check interval in seconds.
    static let sessionCleanupInterval: TimeInterval = 5.0

    /// Grace period before removing dead sessions.
    static let sessionRemovalGraceSeconds: TimeInterval = 3.0

    /// Minimum content length to scan for dangerous patterns.
    /// Short content can't contain both file I/O and network code.
    static let minContentScanLength = 50

    /// Default approval panel dimensions.
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 480

    /// Tools that are user interaction, not tool execution.
    /// These should pass through to Claude's built-in UI.
    static let userInteractionTools = ["AskUserQuestion", "ExitPlanMode"]

    /// Temp-like directory prefixes where content scanning applies.
    /// Files written outside these paths skip polyglot exfil detection.
    static let tempDirectoryPrefixes = ["/tmp/", "/var/tmp/", "/private/tmp/", "/var/folders/"]
}
