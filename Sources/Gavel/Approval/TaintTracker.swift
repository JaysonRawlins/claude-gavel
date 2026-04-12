import Foundation

/// Tracks sensitive data flow across tool calls to detect multi-step exfiltration.
///
/// When a command copies sensitive data (SSH keys, AWS creds, etc.) to a temp/intermediate
/// file, that path is "tainted." If a later command sends a tainted file over the network
/// or executes a tainted binary, it is blocked.
///
/// This catches attacks that split "read credentials" and "send data" across separate
/// Bash calls where each individual call looks innocent.
struct TaintTracker {

    /// File paths that contain sensitive data -- when referenced in a command
    /// that redirects/copies output, the destination becomes tainted.
    private static let sensitiveSourcePatterns = [
        "\\.ssh/", "\\.gnupg/", "\\.aws/", "\\.kube/config",
        "\\.env$", "\\.npmrc$", "\\.netrc$", "\\.docker/config",
    ]

    /// Commands that can send data over the network -- used to detect
    /// exfiltration of tainted files.
    private static let networkExfilPatterns = [
        "\\bcurl\\b", "\\bwget\\b", "\\bscp\\b", "\\brsync\\b",
        "\\bpython3?\\b.*\\b(urlopen|requests|socket)",
        "\\bnc\\b", "\\bncat\\b", "\\bopenssl\\b.*s_client",
    ]

    /// Check if a command exfiltrates or executes any tainted file.
    /// Returns a block reason if detected, nil if safe.
    static func checkExfiltration(command: String, taintedPaths: Set<String>) -> String? {
        guard !taintedPaths.isEmpty else { return nil }
        let range = NSRange(command.startIndex..., in: command)

        for taintedPath in taintedPaths {
            guard command.contains(taintedPath) else { continue }

            if let reason = checkNetworkExfil(command: command, taintedPath: taintedPath, range: range) {
                return reason
            }
            if let reason = checkDirectExecution(command: command, taintedPath: taintedPath, range: range) {
                return reason
            }
        }
        return nil
    }

    /// Record new tainted paths from a command that copies sensitive data.
    static func recordTaints(command: String, into taintedPaths: inout Set<String>) {
        guard referencesSensitiveSource(command) else { return }
        extractRedirectTarget(from: command, into: &taintedPaths)
        extractCompileOutput(from: command, into: &taintedPaths)
        extractCopyDestination(from: command, into: &taintedPaths)
    }

    // MARK: - Private

    private static func checkNetworkExfil(command: String, taintedPath: String, range: NSRange) -> String? {
        for pattern in networkExfilPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: command, range: range) != nil {
                return "Taint detected: \(taintedPath) contains sensitive data and is being sent over network"
            }
        }
        return nil
    }

    private static func checkDirectExecution(command: String, taintedPath: String, range: NSRange) -> String? {
        let escapedPath = NSRegularExpression.escapedPattern(for: taintedPath)
        let positions = [
            "^\\s*\(escapedPath)\\b",
            "&&\\s*\(escapedPath)\\b",
            ";\\s*\(escapedPath)\\b",
            "\\|\\s*\(escapedPath)\\b",
        ]
        for pattern in positions {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: command, range: range) != nil {
                return "Taint detected: executing Claude-compiled binary \(taintedPath)"
            }
        }
        return nil
    }

    private static func referencesSensitiveSource(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        for pattern in sensitiveSourcePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: command, range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func extractRedirectTarget(from command: String, into paths: inout Set<String>) {
        guard let regex = try? NSRegularExpression(pattern: #">>?\s*(\S+)"#),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let pathRange = Range(match.range(at: 1), in: command) else { return }
        paths.insert(String(command[pathRange]))
    }

    private static func extractCompileOutput(from command: String, into paths: inout Set<String>) {
        if let regex = try? NSRegularExpression(pattern: #"\b(gcc|g\+\+|clang|rustc|swiftc|javac)\b.*-o\s+(\S+)"#),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let pathRange = Range(match.range(at: 2), in: command) {
            paths.insert(String(command[pathRange]))
        }
        if let regex = try? NSRegularExpression(pattern: #"\bgo\s+build\b.*-o\s+(\S+)"#),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let pathRange = Range(match.range(at: 1), in: command) {
            paths.insert(String(command[pathRange]))
        }
    }

    private static func extractCopyDestination(from command: String, into paths: inout Set<String>) {
        guard let regex = try? NSRegularExpression(pattern: #"\b(cp|mv)\b\s+\S+\s+(/\S+)"#),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let pathRange = Range(match.range(at: 2), in: command) else { return }
        paths.insert(String(command[pathRange]))
    }
}
