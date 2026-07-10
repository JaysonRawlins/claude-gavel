import Foundation

/// Exposes the loopback review server to the tailnet via `tailscale serve`
/// and builds the public review URL.
///
/// Serve only, NEVER funnel: reachability is limited to WireGuard-
/// authenticated tailnet peers. A dedicated HTTPS port keeps the mapping
/// from clobbering any serve config the user runs on 443.
///
/// Discovery + registration re-run per link with a short (60s) result
/// cache: fresh enough that a `tailscale serve reset` or daemon flap can't
/// leave stale links for long, but a burst of approvals (every one now
/// carries a full-command link) doesn't fork two CLI probes each — and a
/// down tailscale (10s command deadline) can't add 10s to every approval.
///
/// A Mac can run SEVERAL independent backends at once: the Tailscale.app
/// system extension plus any number of homebrew tailscaleds with custom
/// `--socket` paths (e.g. tailscaled-personal.sock for a second tailnet).
/// A CLI run without --socket silently falls back to the GUI extension's
/// IPC, so binary discovery alone probes the wrong daemon. Discovery is
/// therefore by ENDPOINT (binary × socket): probe every /var/run
/// tailscaled socket plus the default GUI discovery, keep the Running
/// ones, and prefer the backend that can see an online iOS peer — that's
/// the tailnet the phone can actually reach.
enum TailscaleServe {

    /// One probed, Running backend and the endpoint that reached it.
    struct Backend {
        let binary: String
        /// Unix socket the CLI must target, nil for default GUI discovery.
        let socketPath: String?
        let host: String
        let hasOnlineIOSPeer: Bool
    }

    /// Hard deadline per CLI invocation. `tailscale serve` BLOCKS
    /// interactively when Serve isn't enabled on the tailnet (prints an
    /// enable URL and waits) — without a deadline that would hang the
    /// approval flow's worker thread.
    static let commandTimeout: TimeInterval = 10

    /// Test seam — production runs a tailscale CLI, tests stub responses.
    /// Returns (exitStatus, stdout); nil when the binary can't be run or
    /// the deadline expired. stderr is discarded deliberately: the CLI
    /// prints version-skew warnings there that would corrupt JSON parsing.
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
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            task.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + commandTimeout) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 2)
            _ = drained.wait(timeout: .now() + 2)
            gavelLog("[review] tailscale \(args.first ?? "?") timed out after \(Int(commandTimeout))s — killed")
            // Partial stdout still matters: the blocked serve prints the
            // tailnet enable URL before waiting.
            return (124, String(decoding: data, as: UTF8.self))
        }
        drained.wait()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Test seam for socket discovery.
    static var socketPaths: () -> [String] = {
        let dir = "/var/run"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { $0.hasPrefix("tailscaled") && $0.hasSuffix(".sock") }
            .sorted()
            .map { dir + "/" + $0 }
    }

    static func candidateBinaries() -> [String] {
        [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var cachedBase: (url: String?, at: Date)?
    private static let cacheLock = NSLock()
    static let cacheTTL: TimeInterval = 60

    /// Cached front-end for `reviewBaseURL()` — successes AND failures both
    /// hold for `cacheTTL` so per-approval links stay cheap either way.
    static func cachedReviewBaseURL(now: Date = Date()) -> String? {
        cacheLock.lock()
        if let cached = cachedBase, now.timeIntervalSince(cached.at) < cacheTTL {
            cacheLock.unlock()
            return cached.url
        }
        cacheLock.unlock()
        let url = reviewBaseURL()
        cacheLock.lock()
        cachedBase = (url, now)
        cacheLock.unlock()
        return url
    }

    /// Test seam — drop the cache so stubs take effect immediately.
    static func resetCache() {
        cacheLock.lock()
        cachedBase = nil
        cacheLock.unlock()
    }

    /// Base URL for review links (e.g. "https://host.tailnet.ts.net:8443"),
    /// or nil when no backend is running — callers fail soft by omitting
    /// the link; the approval itself is never affected.
    static func reviewBaseURL() -> String? {
        let binaries = candidateBinaries()
        guard let cli = binaries.first else {
            gavelLog("[review] no tailscale CLI installed — no review link")
            return nil
        }

        // Socket endpoints first: explicitly-configured daemons beat the
        // GUI-discovery fallback when both are Running and phoneless.
        var endpoints: [(binary: String, socketPath: String?)] =
            socketPaths().map { (cli, $0) }
        endpoints += binaries.map { ($0, nil) }

        var running: [Backend] = []
        for endpoint in endpoints {
            let args = socketArgs(endpoint.socketPath) + ["status", "--json"]
            guard let result = runner(endpoint.binary, args), result.status == 0,
                  let backend = backend(
                      binary: endpoint.binary, socketPath: endpoint.socketPath,
                      statusJSON: Data(result.stdout.utf8)) else { continue }
            // Default-discovery probes from different binaries can reach the
            // same daemon — one entry per node is enough.
            if !running.contains(where: { $0.host == backend.host }) {
                running.append(backend)
            }
        }

        guard let chosen = running.first(where: { $0.hasOnlineIOSPeer }) ?? running.first else {
            gavelLog("[review] no running tailscale backend — no review link")
            return nil
        }
        if running.count > 1 {
            gavelLog("[review] \(running.count) tailscale backends running — chose \(chosen.host) (socket=\(chosen.socketPath ?? "default"), iOS peer online=\(chosen.hasOnlineIOSPeer))")
        }

        let target = "http://127.0.0.1:\(GavelConstants.reviewServerPort)"
        let serveArgs = socketArgs(chosen.socketPath)
            + ["serve", "--bg", "--https=\(GavelConstants.reviewTailnetHTTPSPort)", target]
        let serve = runner(chosen.binary, serveArgs)
        guard let serve, serve.status == 0 else {
            handleServeFailure(output: serve?.stdout ?? "")
            return nil
        }
        return "https://\(chosen.host):\(GavelConstants.reviewTailnetHTTPSPort)"
    }

    private static func socketArgs(_ socketPath: String?) -> [String] {
        socketPath.map { ["--socket=\($0)"] } ?? []
    }

    /// Tracks the one-time "enable Serve on your tailnet" notification so a
    /// disabled tailnet doesn't ping the user on every commit.
    private static var notifiedServeDisabled = false
    private static let notifyLock = NSLock()

    static func handleServeFailure(output: String) {
        gavelLog("[review] tailscale serve registration failed")
        guard let url = enableURL(fromServeOutput: output) else { return }
        notifyLock.lock()
        let alreadyNotified = notifiedServeDisabled
        notifiedServeDisabled = true
        notifyLock.unlock()
        guard !alreadyNotified else { return }
        GavelNotifications.notify(
            title: "Gavel — enable Tailscale Serve",
            body: "Phone diff review needs Serve enabled on your tailnet (one-time):\n\(url)"
        )
    }

    /// Extracts the admin-console enable link from the CLI's "Serve is not
    /// enabled on your tailnet" output.
    static func enableURL(fromServeOutput output: String) -> String? {
        guard output.contains("Serve is not enabled") else { return nil }
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .first { $0.hasPrefix("https://login.tailscale.com/f/serve") }
            ?? "https://login.tailscale.com"
    }

    /// Parses `tailscale status --json` into a Backend. Nil unless the
    /// backend is actually Running — a stopped tailscaled still reports a
    /// DNSName but can't route.
    static func backend(binary: String, socketPath: String?, statusJSON data: Data) -> Backend? {
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
        return Backend(binary: binary, socketPath: socketPath, host: dns, hasOnlineIOSPeer: hasPhone)
    }
}
