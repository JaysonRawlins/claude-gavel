import Foundation

/// Site-scoped session lease for claude-in-chrome automation.
///
/// Granted from a navigate approval ("Allow Site"); auto-allows the
/// high-frequency page-interaction tools on that site so a driven page
/// doesn't cost one prompt per click. Revoked the moment a driven tab
/// reports a URL off the leased domain — the drift is visible in the SAME
/// tool response that caused it, so exposure is bounded to one
/// already-approved action — or on TTL expiry, manual revoke, or
/// `revokeAutoApprove`.
struct BrowsingLease {
    let domain: String  // normalized host, e.g. "example.com"
    let grantedAt: Date
    let ttl: TimeInterval

    static let defaultTTL: TimeInterval = 30 * 60

    static let chromeToolPrefix = "mcp__claude-in-chrome__"
    static let navigateTool = chromeToolPrefix + "navigate"

    /// Tools a lease may auto-allow. Deliberately excludes the exfil-grade
    /// tools (javascript_tool, file_upload, upload_image, shortcuts_execute)
    /// and tab lifecycle — those keep their normal prompt tier regardless of
    /// any lease.
    static let leaseSafeTools: Set<String> = [
        chromeToolPrefix + "computer",
        chromeToolPrefix + "form_input",
    ]

    /// Tools whose responses must re-confirm the leased domain (all carry the
    /// extension's "Tab Context" block with an "Executed on tabId" line).
    static let driftCheckedTools: Set<String> = leaseSafeTools.union([navigateTool])

    var expiresAt: Date { grantedAt.addingTimeInterval(ttl) }
    var isActive: Bool { Date() < expiresAt }

    init(domain: String, grantedAt: Date = Date(), ttl: TimeInterval = BrowsingLease.defaultTTL) {
        self.domain = domain
        self.grantedAt = grantedAt
        self.ttl = ttl
    }

    /// Normalize a URL (with or without scheme — navigate accepts both) to a
    /// comparable host. "www." is stripped so example.com and www.example.com
    /// are one site; everything else is exact-host, so sub.example.com is a
    /// DIFFERENT site than example.com (stricter beats eTLD+1 cleverness).
    static func normalizedHost(fromURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URL(string: withScheme)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func covers(urlString: String) -> Bool {
        Self.normalizedHost(fromURL: urlString) == domain
    }

    /// Whether this lease allows the tool call. Returns a human-readable
    /// reason on allow; nil falls through to the normal prompt tiers.
    func allows(toolName: String, url: String?) -> String? {
        guard isActive else { return nil }
        if Self.leaseSafeTools.contains(toolName) {
            return "Browsing lease: \(domain)"
        }
        if toolName == Self.navigateTool, let url, covers(urlString: url) {
            return "Browsing lease: \(domain) (same-site navigate)"
        }
        return nil
    }

    // MARK: - Drift detection

    /// Inspect a chrome tool response for domain drift. Returns a revocation
    /// reason if the executed tab is off-domain, or if the response carries
    /// no parseable executed-tab URL (fail closed — a lease only survives
    /// while responses keep proving the domain).
    static func driftReason(inResponse text: String, domain: String) -> String? {
        guard let executedURL = executedTabURL(inResponse: text) else {
            return "response missing executed-tab URL (fail closed)"
        }
        if let host = normalizedHost(fromURL: executedURL), host == domain {
            return nil
        }
        let drifted = normalizedHost(fromURL: executedURL) ?? executedURL
        return "tab drifted to \(drifted)"
    }

    /// Parse the executed tab's URL out of the "Tab Context" block the chrome
    /// extension appends to every tool result:
    ///
    ///     Tab Context:
    ///     - Executed on tabId: 2140008915
    ///     - Available tabs:
    ///       • tabId 2140008915: "Example Domain" (https://example.com/)
    ///
    /// The URL is the last parenthesized span on the executed tab's line, so
    /// titles containing parentheses don't break the parse.
    static func executedTabURL(inResponse text: String) -> String? {
        guard let idMatch = firstRegexMatch(#"Executed on tabId:\s*(\d+)"#, in: text) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.contains("tabId \(idMatch):") {
            // Skip the "Executed on tabId: N" line itself (no URL on it).
            guard let open = line.lastIndex(of: "("),
                  let close = line.lastIndex(of: ")"),
                  open < close
            else { continue }
            let url = String(line[line.index(after: open)..<close])
            if !url.isEmpty { return url }
        }
        return nil
    }

    private static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
