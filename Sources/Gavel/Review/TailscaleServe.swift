import Foundation

/// Exposes the loopback review server to the tailnet via `tailscale serve`
/// and builds the public review URL.
///
/// Serve only, NEVER funnel: reachability is limited to WireGuard-
/// authenticated tailnet peers. A dedicated HTTPS port keeps the mapping
/// from clobbering any serve config the user runs on 443.
///
/// No caching: status + registration re-run per review so a `tailscale
/// serve reset` or daemon flap between commits can't leave stale links.
/// Both calls are ~50ms against the local tailscaled.
enum TailscaleServe {

    /// Test seam — production runs the tailscale CLI, tests stub responses.
    /// Returns (exitStatus, stdout) or nil when the binary can't be run.
    static var runner: (_ args: [String]) -> (status: Int32, stdout: String)? = { args in
        guard let binary = binaryPath() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        drained.wait()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func binaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Base URL for review links (e.g. "https://host.tailnet.ts.net:8443"),
    /// or nil when tailscale is missing/stopped — callers fail soft by
    /// omitting the link; the approval itself is never affected.
    static func reviewBaseURL() -> String? {
        guard let status = runner(["status", "--json"]), status.status == 0,
              let host = hostname(fromStatusJSON: Data(status.stdout.utf8)) else {
            gavelLog("[review] tailscale unavailable — no review link")
            return nil
        }
        let target = "http://127.0.0.1:\(GavelConstants.reviewServerPort)"
        guard let serve = runner(["serve", "--bg", "--https=\(GavelConstants.reviewTailnetHTTPSPort)", target]),
              serve.status == 0 else {
            gavelLog("[review] tailscale serve registration failed")
            return nil
        }
        return "https://\(host):\(GavelConstants.reviewTailnetHTTPSPort)"
    }

    /// Extracts the node's MagicDNS name from `tailscale status --json`.
    /// Nil unless the backend is actually running — a stopped tailscaled
    /// still reports a DNSName but can't route.
    static func hostname(fromStatusJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["BackendState"] as? String == "Running",
              let selfNode = root["Self"] as? [String: Any],
              var dns = selfNode["DNSName"] as? String, !dns.isEmpty else {
            return nil
        }
        if dns.hasSuffix(".") { dns.removeLast() }
        return dns
    }
}
