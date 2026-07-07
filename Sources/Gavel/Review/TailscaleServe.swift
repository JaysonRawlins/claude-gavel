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
///
/// A Mac can run TWO independent backends at once (the Tailscale.app system
/// extension and a homebrew tailscaled), each with its own node identity and
/// CLI. Backend choice is therefore by state, not binary path: probe every
/// candidate CLI, keep the Running ones, and prefer the backend that can see
/// an online iOS peer — that's the one the phone can actually reach.
enum TailscaleServe {

    /// One probed backend: the CLI that reached it, its MagicDNS name, and
    /// whether an iOS device is currently online on its tailnet.
    struct Backend {
        let binary: String
        let host: String
        let hasOnlineIOSPeer: Bool
    }

    /// Test seam — production runs a tailscale CLI, tests stub responses.
    /// Returns (exitStatus, stdout) or nil when the binary can't be run.
    /// stderr is discarded deliberately: the CLI prints version-skew
    /// warnings there that would corrupt JSON parsing if merged.
    static var runner: (_ binary: String, _ args: [String]) -> (status: Int32, stdout: String)? = { binary, args in
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

    static func candidateBinaries() -> [String] {
        [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Base URL for review links (e.g. "https://host.tailnet.ts.net:8443"),
    /// or nil when no backend is running — callers fail soft by omitting
    /// the link; the approval itself is never affected.
    static func reviewBaseURL() -> String? {
        let running = candidateBinaries().compactMap { binary -> Backend? in
            guard let result = runner(binary, ["status", "--json"]), result.status == 0 else { return nil }
            return backend(binary: binary, statusJSON: Data(result.stdout.utf8))
        }
        guard let chosen = running.first(where: { $0.hasOnlineIOSPeer }) ?? running.first else {
            gavelLog("[review] no running tailscale backend — no review link")
            return nil
        }
        if running.count > 1 {
            gavelLog("[review] \(running.count) tailscale backends running — chose \(chosen.host) (\(chosen.binary), iOS peer online=\(chosen.hasOnlineIOSPeer))")
        }
        let target = "http://127.0.0.1:\(GavelConstants.reviewServerPort)"
        guard let serve = runner(chosen.binary, ["serve", "--bg", "--https=\(GavelConstants.reviewTailnetHTTPSPort)", target]),
              serve.status == 0 else {
            gavelLog("[review] tailscale serve registration failed via \(chosen.binary)")
            return nil
        }
        return "https://\(chosen.host):\(GavelConstants.reviewTailnetHTTPSPort)"
    }

    /// Parses `tailscale status --json` into a Backend. Nil unless the
    /// backend is actually Running — a stopped tailscaled still reports a
    /// DNSName but can't route.
    static func backend(binary: String, statusJSON data: Data) -> Backend? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["BackendState"] as? String == "Running",
              let selfNode = root["Self"] as? [String: Any],
              var dns = selfNode["DNSName"] as? String, !dns.isEmpty else {
            return nil
        }
        if dns.hasSuffix(".") { dns.removeLast() }

        let peers = root["Peer"] as? [String: [String: Any]] ?? [:]
        let hasPhone = peers.values.contains { peer in
            peer["OS"] as? String == "iOS" && peer["Online"] as? Bool == true
        }
        return Backend(binary: binary, host: dns, hasOnlineIOSPeer: hasPhone)
    }
}
