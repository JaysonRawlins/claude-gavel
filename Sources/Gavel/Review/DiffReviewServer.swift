import Foundation
import Network

/// A verdict POSTed from the review page.
struct ReviewVerdictSubmission: Codable {
    let verdict: String
    let note: String?
    let comments: [ReviewComment]?
    /// arg name → regex for verdict "allow_scoped" (command pages only).
    let conditions: [String: String]?

    init(verdict: String, note: String?, comments: [ReviewComment]? = nil, conditions: [String: String]? = nil) {
        self.verdict = verdict
        self.note = note
        self.comments = comments
        self.conditions = conditions
    }
}

struct ReviewComment: Codable {
    let file: String
    let line: Int?
    let text: String
}

/// Loopback HTTP server that serves pending commit reviews and accepts their
/// verdicts as a `.web` resolver racing the Mac panel and Telegram.
///
/// Security model: the listener only ever binds 127.0.0.1 — tailnet
/// reachability comes exclusively via `tailscale serve` (WireGuard-
/// authenticated peers), never `tailscale funnel`. The per-review nonce is
/// the sole capability: unknown nonces get a uniform 404, resolved reviews
/// stop serving diff content, and a verdict can only ever win the resolution
/// race once (ResolvableApproval guarantees exactly-one-Decision).
final class DiffReviewServer {

    static let shared = DiffReviewServer()

    /// What a registered nonce serves: a commit diff or a full-command page.
    enum PageContent {
        case diff(ReviewContent)
        case command(CommandContent)
    }

    final class ReviewSession {
        let nonce: String
        let content: PageContent
        let resolvable: ResolvableApproval
        /// Creates a persistent scoped allow rule from submitted arg
        /// conditions and returns the rule's display name. Only set for
        /// command pages whose approval may author a durable allow — its
        /// absence makes verdict "allow_scoped" a 400.
        let createScopedAllow: (([String: String]) -> String)?
        let createdAt = Date()
        /// Set (under the server lock) once any source resolves the approval.
        var resolvedBy: ResolvableApproval.Source?
        var resolvedAt: Date?
        /// Set (under the server lock) on the first GET of the still-pending
        /// review page — the evidence that a human actually opened the diff.
        /// GETs after resolution serve the "already resolved" page and never
        /// set this, so it can't be back-filled once the race is over.
        var viewedAt: Date?

        init(nonce: String, content: PageContent, resolvable: ResolvableApproval, createScopedAllow: (([String: String]) -> String)? = nil) {
            self.nonce = nonce
            self.content = content
            self.resolvable = resolvable
            self.createScopedAllow = createScopedAllow
        }
    }

    private let queue = DispatchQueue(label: "gavel.review-server")
    private let lock = NSLock()
    private var sessions: [String: ReviewSession] = [:]
    private var listener: NWListener?
    /// Actual bound port — differs from the requested one when tests pass 0.
    private(set) var boundPort: UInt16?

    // MARK: - Lifecycle

    /// Starts the listener if not already running. Blocks until the socket is
    /// ready so callers can trust `boundPort`. Idempotent.
    func start(port: UInt16 = GavelConstants.reviewServerPort) throws {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let nw = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?

        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = nw.port?.rawValue
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        nw.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        nw.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, startError == nil else {
            nw.cancel()
            throw startError ?? NSError(
                domain: "gavel.review", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "review server start timed out"])
        }

        lock.lock()
        listener = nw
        lock.unlock()
        gavelLog("[review] server listening on 127.0.0.1:\(boundPort ?? 0)")
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        sessions.removeAll()
        lock.unlock()
    }

    // MARK: - Registration

    /// Registers a commit-diff review for a pending approval and returns its nonce.
    /// The review dies with the approval: any resolution (mac / telegram /
    /// timeout / web) flips it to the "already resolved" page.
    func register(content: ReviewContent, resolvable: ResolvableApproval) -> String {
        register(page: .diff(content), resolvable: resolvable, reviewedNoun: "the diff")
    }

    /// Registers a full-command page for a pending approval — the phone-side
    /// twin of the Mac panel's command view, so the unredacted command never
    /// has to transit Telegram. `createScopedAllow` (when the approval may
    /// author a durable allow) turns submitted arg conditions into a
    /// persistent rule and returns its name.
    func register(command: CommandContent, resolvable: ResolvableApproval, createScopedAllow: (([String: String]) -> String)? = nil) -> String {
        register(page: .command(command), resolvable: resolvable, reviewedNoun: "the full command", createScopedAllow: createScopedAllow)
    }

    private func register(page: PageContent, resolvable: ResolvableApproval, reviewedNoun: String, createScopedAllow: (([String: String]) -> String)? = nil) -> String {
        pruneStale()

        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        let nonce = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let session = ReviewSession(nonce: nonce, content: page, resolvable: resolvable, createScopedAllow: createScopedAllow)
        lock.lock()
        sessions[nonce] = session
        lock.unlock()

        resolvable.addCleanup { [weak self] source, _ in
            guard let self else { return }
            self.lock.lock()
            session.resolvedBy = source
            session.resolvedAt = Date()
            self.lock.unlock()
        }
        // Reviewed-and-approved vs approved-on-trust: when the review page
        // was opened before the approval resolved, tell the agent — whichever
        // responder (Mac panel / Telegram / web) wins the race.
        resolvable.addDecisionTransform { [weak self] decision, _ in
            guard let self, decision.verdict == .allow else { return decision }
            self.lock.lock()
            let viewed = session.viewedAt != nil
            self.lock.unlock()
            guard viewed else { return decision }
            gavelLog("[review] reviewed-signal attached nonce=\(nonce.prefix(8))…")
            // Standalone form when there's no note; appended line otherwise.
            let hasNote = !(decision.additionalContext?.isEmpty ?? true)
            return decision.appendingContext(hasNote
                ? "User reviewed \(reviewedNoun) before approving."
                : "User approved this via Gavel — user reviewed \(reviewedNoun) before approving")
        }
        return nonce
    }

    private func session(for nonce: String) -> ReviewSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[nonce]
    }

    /// Drops resolved reviews past the TTL and unresolved ones past the
    /// approval timeout (their worker already failed closed).
    private func pruneStale() {
        let now = Date()
        lock.lock()
        sessions = sessions.filter { _, s in
            if let resolvedAt = s.resolvedAt {
                return now.timeIntervalSince(resolvedAt) < GavelConstants.reviewResolvedTTL
            }
            return now.timeIntervalSince(s.createdAt) < GavelConstants.approvalTimeoutSeconds
        }
        lock.unlock()
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Hard connection deadline: a client that stalls mid-request can't
        // hold the (serial) server queue's buffers forever.
        queue.asyncAfter(deadline: .now() + 15) {
            connection.cancel()
        }
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }
            if buffer.count > GavelConstants.reviewMaxBodyBytes + 8 * 1024 {
                self.send(connection, status: 413, body: "payload too large")
                return
            }
            if let request = HTTPRequest.parse(buffer) {
                self.route(request, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffered: buffer)
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        let parts = request.path.split(separator: "/").map(String.init)

        // GET /review/<nonce>
        if request.method == "GET", parts.count == 2, parts[0] == "review" {
            guard let session = session(for: parts[1]) else {
                send(connection, status: 404, body: "not found")
                return
            }
            lock.lock()
            let resolvedBy = session.resolvedBy
            let firstView = resolvedBy == nil && session.viewedAt == nil
            if firstView { session.viewedAt = Date() }
            lock.unlock()
            if firstView {
                gavelLog("[review] page viewed nonce=\(session.nonce.prefix(8))…")
            }
            let page: String
            if let resolvedBy {
                page = DiffHTML.resolvedPage(by: label(resolvedBy))
            } else {
                switch session.content {
                case .diff(let content): page = DiffHTML.page(content: content)
                case .command(let content): page = CommandHTML.page(content: content)
                }
            }
            send(connection, status: 200, body: page, contentType: "text/html; charset=utf-8")
            return
        }

        // POST /review/<nonce>/verdict
        if request.method == "POST", parts.count == 3, parts[0] == "review", parts[2] == "verdict" {
            guard let session = session(for: parts[1]) else {
                send(connection, status: 404, body: "not found")
                return
            }
            guard request.body.count <= GavelConstants.reviewMaxBodyBytes else {
                send(connection, status: 413, body: "payload too large")
                return
            }
            guard let submission = try? JSONDecoder().decode(ReviewVerdictSubmission.self, from: request.body) else {
                send(connection, status: 400, body: "bad request")
                return
            }
            lock.lock()
            let alreadyResolved = session.resolvedBy != nil
            lock.unlock()
            if alreadyResolved {
                send(connection, status: 409, body: "{\"status\":\"already_resolved\"}", contentType: "application/json")
                return
            }

            let decision: Decision?
            if submission.verdict == "allow_scoped" {
                // Durable-allow authoring: only pages registered with a
                // createScopedAllow callback (MCP + not Allow-once-only) may
                // do this, and every condition regex must be present + valid.
                guard let create = session.createScopedAllow,
                      let conditions = Self.cleanedConditions(submission.conditions) else {
                    send(connection, status: 400, body: "bad request")
                    return
                }
                // Rule creation precedes the resolution race, matching the Mac
                // panel's Always Allow: if another responder wins the next
                // instant, the explicitly-requested rule still persists.
                let ruleName = create(conditions)
                gavelLog("[review] scoped allow rule authored nonce=\(session.nonce.prefix(8))… args=\(conditions.keys.sorted().joined(separator: ","))")
                let note = submission.note.flatMap { $0.isEmpty ? nil : $0 }
                decision = Decision(
                    verdict: .allow,
                    reason: "Approved from command review page — always allow: \(ruleName)",
                    additionalContext: note.map { "Approver note from review page: \($0)" })
            } else {
                decision = Self.decision(for: submission)
            }
            guard let decision else {
                send(connection, status: 400, body: "bad request")
                return
            }
            if !session.resolvable.resolve(decision, from: .web) {
                send(connection, status: 409, body: "{\"status\":\"already_resolved\"}", contentType: "application/json")
                return
            }
            gavelLog("[review] web verdict=\(submission.verdict) comments=\(submission.comments?.count ?? 0) nonce=\(session.nonce.prefix(8))…")
            send(connection, status: 200, body: "{\"status\":\"ok\"}", contentType: "application/json")
            return
        }

        send(connection, status: 404, body: "not found")
    }

    private func send(_ connection: NWConnection, status: Int, body: String, contentType: String = "text/plain; charset=utf-8") {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let payload = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(payload.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Trim submitted conditions, drop blank rows, and require every regex to
    /// compile. Nil (→ 400) when nothing usable remains or a pattern is
    /// invalid — a scoped rule must never be created from garbage input.
    static func cleanedConditions(_ raw: [String: String]?) -> [String: String]? {
        guard let raw else { return nil }
        var cleaned: [String: String] = [:]
        for (key, pattern) in raw {
            let name = key.trimmingCharacters(in: .whitespaces)
            let pat = pattern.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !pat.isEmpty else { continue }
            guard (try? NSRegularExpression(pattern: pat)) != nil else { return nil }
            cleaned[name] = pat
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Verdict mapping

    /// Maps a web submission onto the existing Decision vocabulary:
    /// approve → allow (+ non-blocking notes), request_changes → block with
    /// the structured comments as the deny reason Claude acts on.
    static func decision(for submission: ReviewVerdictSubmission) -> Decision? {
        let comments = submission.comments ?? []
        var lines = comments.map { c in
            "\(c.file):\(c.line ?? 0) — \(c.text)"
        }
        if let note = submission.note, !note.isEmpty {
            lines.append("Overall: \(note)")
        }

        switch submission.verdict {
        case "approve":
            let context = lines.isEmpty
                ? nil
                : "Code review notes (non-blocking):\n" + lines.joined(separator: "\n")
            return Decision(
                verdict: .allow, reason: "User approved via web review",
                additionalContext: context)
        case "request_changes":
            var reason = "Code review — changes requested"
            reason += comments.isEmpty ? ":" : " (\(comments.count) comment\(comments.count == 1 ? "" : "s")):"
            reason += "\n" + (lines.isEmpty ? "See the review page — no comment text was attached." : lines.joined(separator: "\n"))
            return Decision(verdict: .block, reason: reason)
        // Full-command page verbs — same wire route, allow/deny semantics.
        case "allow":
            let note = submission.note.flatMap { $0.isEmpty ? nil : $0 }
            return Decision(
                verdict: .allow, reason: "Approved from command review page",
                additionalContext: note.map { "Approver note from review page: \($0)" })
        case "deny":
            let note = submission.note.flatMap { $0.isEmpty ? nil : $0 }
            return Decision(
                verdict: .block,
                reason: "Denied from command review page" + (note.map { " — \($0)" } ?? ""))
        default:
            return nil
        }
    }

    private func label(_ source: ResolvableApproval.Source) -> String {
        switch source {
        case .mac: return "the Mac panel"
        case .telegram: return "Telegram"
        case .timeout: return "timeout"
        case .autoApprove: return "auto-approve"
        case .web: return "this review page"
        }
    }
}

/// Minimal HTTP/1.1 request parser — just enough for the two review routes.
/// Returns nil until the full head and Content-Length body have arrived.
struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        // Strip any query string; the routes don't use one.
        let path = String(parts[1]).components(separatedBy: "?")[0]

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let body = data[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return HTTPRequest(method: method, path: path, body: Data(body.prefix(contentLength)))
    }
}
