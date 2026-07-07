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

    /// Socket read timeout in seconds. Generous because the bound is on each
    /// `read()` call, not the whole conversation. Under burst load (e.g. five
    /// parallel `gavel-hook` subprocesses launching at once), an individual
    /// hook can be descheduled between `connect()` and `write()` for hundreds
    /// of milliseconds; a 2-second cap was tight enough that one hook in the
    /// burst would time out, fail closed, and Claude Code would then SIGTERM
    /// the surviving siblings as parallel-call cancellation. 30 seconds is
    /// loose enough for any realistic scheduling delay yet still bounded so a
    /// truly stuck client can't hold a worker thread indefinitely.
    static let socketReadTimeoutSeconds: Int = 30

    /// Stats update interval in seconds.
    static let statsUpdateInterval: TimeInterval = 2.0

    /// Session cleanup check interval in seconds.
    static let sessionCleanupInterval: TimeInterval = 5.0

    /// Tombstone retention. The dead-session store is otherwise append-only, so a
    /// runaway respawn loop (e.g. a `/loop` spawning a fresh CLI every ~90s) can
    /// pile up thousands of permanent rows. Keep at most this many tombstones, and
    /// drop any older than the TTL — whichever removes more.
    static let maxDeadSessions = 200
    static let deadSessionTTL: TimeInterval = 14 * 24 * 60 * 60

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

    /// Telegram long-poll hold time in seconds (server-side `getUpdates` timeout).
    static let telegramPollTimeoutSeconds = 30

    /// Max characters of the redacted command shown in a Telegram approval (under Telegram's 4096 limit).
    static let telegramBodyMaxChars = 3500

    /// Minimum length of an alphanumeric run treated as credential-shaped by the
    /// credential gate's entropy heuristic.
    static let credentialEntropyRunLength = 20

    /// Loopback port for the diff review server. Only ever bound to 127.0.0.1;
    /// tailnet reachability comes exclusively via `tailscale serve`.
    static let reviewServerPort: UInt16 = 48765

    /// Tailnet-side HTTPS port for review links. Dedicated port so the serve
    /// mapping never clobbers anything the user serves on 443.
    static let reviewTailnetHTTPSPort: UInt16 = 8443

    /// Cap on a review verdict POST body.
    static let reviewMaxBodyBytes = 64 * 1024

    /// Cap on captured diff text. Bigger diffs are truncated with a banner —
    /// a phone review of a multi-megabyte diff isn't a real review anyway.
    static let reviewDiffMaxBytes = 2 * 1024 * 1024

    /// How long a resolved review stays retrievable (shows "resolved by …"
    /// instead of 404) before it's garbage-collected.
    static let reviewResolvedTTL: TimeInterval = 3600
}
