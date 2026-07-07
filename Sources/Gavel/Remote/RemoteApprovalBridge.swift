import Foundation
import Security

/// Bridges pending approvals to a Telegram bot and races inbound button taps
/// against the on-Mac panel. Additive: the local panel stays authoritative.
final class RemoteApprovalBridge {

    static weak var shared: RemoteApprovalBridge?

    private final class Correlation {
        let nonce: String
        let pid: Int
        let toolName: String
        let resolvable: ResolvableApproval
        let allowSession: (() -> Void)?
        let allowSite: (() -> Void)?
        var messageId: Int?
        init(
            nonce: String, pid: Int, toolName: String, resolvable: ResolvableApproval,
            allowSession: (() -> Void)?, allowSite: (() -> Void)? = nil
        ) {
            self.nonce = nonce
            self.pid = pid
            self.toolName = toolName
            self.resolvable = resolvable
            self.allowSession = allowSession
            self.allowSite = allowSite
        }
    }

    private let transport: TelegramTransport
    private let redact: (String) -> String
    private let lock = NSLock()
    private var byNonce: [String: Correlation] = [:]
    private var promptReplies: [Int: PendingReply] = [:]
    private var pendingOrder: [String] = []
    private var offset = 0
    private var running = false
    private var backoff: TimeInterval = 1
    private var chatId: Int64?

    private var sendTokens = 5.0
    private var lastRefill = Date()
    private var coalescedCount = 0
    private var lastCoalesceNotice: Date?

    /// Fired when pairing captures a chat id, so the daemon can persist it.
    var onPaired: ((Int64) -> Void)?
    /// Fired when the pinned chat sends `[[/stop-phone]]`, so the daemon can kill phone approval.
    var onStopPhone: (() -> Void)?
    /// Emits a token-redacted status line for the feed/log.
    var onStatus: ((String) -> Void)?
    /// Emits a gavel.log-only trail of remote sends/resolutions (no UI feed, no secrets).
    var remoteLog: ((String) -> Void)?

    init(transport: TelegramTransport, chatId: Int64?, redact: @escaping (String) -> String = { $0 }) {
        self.transport = transport
        self.chatId = chatId
        self.redact = redact
    }

    var isPaired: Bool {
        lock.lock(); defer { lock.unlock() }
        return chatId != nil
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        RemoteApprovalBridge.shared = self
        pollOnce()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: - Outbound

    /// Send a pending approval to the phone and register it for inbound resolution.
    /// `leaseDomain`/`allowSite` (both required together) add a browsing-lease
    /// button for chrome navigate approvals — the phone twin of the panel's
    /// "Allow Site" (see BrowsingLease).
    func notify(resolvable: ResolvableApproval, text: String, pid: Int = 0, toolName: String = "", withheld: Bool = false, allowSession: (() -> Void)?, offerCommentClean: Bool = false, leaseDomain: String? = nil, allowSite: (() -> Void)? = nil, reviewURL: String? = nil) {
        lock.lock(); let chat = chatId; lock.unlock()
        guard let chat else { return }

        guard consumeSendToken() else {
            remoteLog?("coalesced pid=\(pid) tool=\(toolName) — flood control, Mac-fallback")
            coalesce(chat: chat)
            return
        }

        let nonce = Self.makeNonce()
        let corr = Correlation(
            nonce: nonce, pid: pid, toolName: toolName, resolvable: resolvable,
            allowSession: allowSession, allowSite: allowSite)
        lock.lock(); byNonce[nonce] = corr; pendingOrder.append(nonce); lock.unlock()

        resolvable.addCleanup { [weak self] source, _ in
            guard let self else { return }
            self.lock.lock(); let mid = corr.messageId; self.lock.unlock()
            self.forget(nonce)
            guard source != .telegram else { return }
            self.remoteLog?("dropped pid=\(pid) nonce=\(nonce) source=\(source)")
            if let mid {
                self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(source), completion: nil)
            }
        }

        var keyboard: [[TelegramButton]] = []
        // Review link leads the keyboard: on a commit approval the intended
        // flow is review first, then verdict (on the page or via the buttons).
        if let reviewURL {
            keyboard.append([TelegramButton(text: "🔍 Review diff", url: reviewURL)])
        }
        keyboard.append(
            [TelegramButton(text: "✅ Allow once", callbackData: "a:\(nonce)"),
             TelegramButton(text: "🛑 Deny", callbackData: "d:\(nonce)")])
        // Allow-once-only approvals (nil allowSession) omit the session button entirely.
        if allowSession != nil {
            keyboard.append([TelegramButton(text: "✅ Allow for session", callbackData: "s:\(nonce)")])
        }
        if allowSite != nil, let leaseDomain {
            keyboard.append([TelegramButton(text: "🌐 Allow site: \(leaseDomain)", callbackData: "g:\(nonce)")])
        }
        keyboard.append([TelegramButton(text: "✅ Allow w/ note", callbackData: "ar:\(nonce)"),
                         TelegramButton(text: "🛑 Deny w/ reason", callbackData: "dr:\(nonce)")])
        if offerCommentClean {
            keyboard.append([TelegramButton(text: "🧹 Clean comments & re-propose", callbackData: "c:\(nonce)")])
        }
        transport.sendMessage(chatId: chat, text: text, keyboard: keyboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mid):
                self.lock.lock(); corr.messageId = mid; self.lock.unlock()
                self.remoteLog?("sent pid=\(pid) nonce=\(nonce) tool=\(toolName) withheld=\(withheld) mid=\(mid)")
                if resolvable.isResolved {
                    self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(.mac), completion: nil)
                    self.forget(nonce)
                }
            case .failure(let error):
                self.remoteLog?("send-failed pid=\(pid) nonce=\(nonce) tool=\(toolName)")
                self.onStatus?("Telegram send failed: \(self.redact("\(error)"))")
            }
        }
    }

    /// Send an unsolicited, keyboard-less notice to the pinned chat (e.g. a stop-phone confirmation).
    func sendNotice(_ text: String) {
        lock.lock(); let chat = chatId; lock.unlock()
        guard let chat else { return }
        transport.sendMessage(chatId: chat, text: text, keyboard: nil, completion: { _ in })
    }

    // MARK: - Inbound poll loop

    private func pollOnce() {
        lock.lock(); let go = running; let off = offset; lock.unlock()
        guard go else { return }
        transport.getUpdates(offset: off, timeoutSeconds: GavelConstants.telegramPollTimeoutSeconds) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updates):
                self.resetBackoff()
                for update in updates { self.handle(update) }
                if let maxId = updates.map(\.updateId).max() {
                    self.lock.lock(); self.offset = maxId + 1; self.lock.unlock()
                }
                self.rearm(after: 0)
            case .failure(let error):
                if case TelegramError.unauthorizedToken = error {
                    self.onStatus?("Telegram disabled — token unauthorized")
                    self.stop()
                    return
                }
                if case TelegramError.rateLimited(let retryAfter) = error {
                    self.rearm(after: retryAfter)
                    return
                }
                let delay = self.bumpBackoff()
                self.onStatus?("Telegram poll error (retry \(Int(delay))s): \(self.redact("\(error)"))")
                self.rearm(after: delay)
            }
        }
    }

    private func rearm(after delay: TimeInterval) {
        lock.lock(); let go = running; lock.unlock()
        guard go else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pollOnce()
        }
    }

    func handle(_ update: TelegramUpdate) {
        if let message = update.message { handleMessage(message); return }
        if let callback = update.callback { handleCallback(callback) }
    }

    private func handleMessage(_ message: TelegramIncomingMessage) {
        lock.lock(); let pinned = chatId; lock.unlock()

        if pinned == nil {
            guard (message.text ?? "").hasPrefix("/start") else { return }
            lock.lock(); chatId = message.chatId; lock.unlock()
            onPaired?(message.chatId)
            transport.sendMessage(
                chatId: message.chatId,
                text: "Gavel paired ✅ — this chat is now the only one that can answer approvals.",
                keyboard: nil,
                completion: { _ in }
            )
            return
        }

        guard let pinned, message.chatId == pinned, message.fromId == pinned else { return }
        guard let text = message.text, !text.isEmpty, !text.hasPrefix("/") else { return }
        if StopPhoneHandler.matches(text) {
            remoteLog?("stop-phone command received")
            onStopPhone?()
            return
        }
        switch typedReplyTarget(replyTo: message.replyToMessageId) {
        case .target(let corr, let kind):
            forget(corr.nonce)
            let decision = Self.typedReplyDecision(kind: kind, text: text)
            let won = corr.resolvable.resolve(decision, from: .telegram)
            remoteLog?("resolved pid=\(corr.pid) nonce=\(corr.nonce) action=\(Self.typedReplyAction(kind)) won=\(won)")
            if won, let mid = corr.messageId {
                transport.editMessageText(chatId: pinned, messageId: mid, text: Self.typedReplyResolvedText(kind: kind, text: text), completion: nil)
            }
        case .ambiguous(let count):
            transport.sendMessage(chatId: pinned, text: "\(count) approvals pending — swipe-reply the specific one you mean, or tap its buttons.", keyboard: nil, completion: { _ in })
        case .none:
            break
        }
    }

    private func handleCallback(_ callback: TelegramCallback) {
        lock.lock(); let pinned = chatId; lock.unlock()
        guard let pinned, callback.chatId == pinned, callback.fromId == pinned else {
            transport.answerCallbackQuery(id: callback.id, text: "Not authorized", completion: nil)
            return
        }

        let parts = callback.data.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            transport.answerCallbackQuery(id: callback.id, text: nil, completion: nil)
            return
        }
        let action = String(parts[0])
        let nonce = String(parts[1])

        lock.lock(); let corr = byNonce[nonce]; lock.unlock()
        guard let corr else {
            transport.answerCallbackQuery(id: callback.id, text: "Already resolved", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: "↪️ Already resolved", completion: nil)
            return
        }

        if action == "dr" {
            promptForReply(corr: corr, kind: .deny, callbackId: callback.id, chat: pinned)
            return
        }
        if action == "ar" {
            promptForReply(corr: corr, kind: .allow, callbackId: callback.id, chat: pinned)
            return
        }
        forget(nonce)

        if action == "s" { corr.allowSession?() }
        if action == "g" { corr.allowSite?() }
        let decision = Self.decision(for: action)
        let won = corr.resolvable.resolve(decision, from: .telegram)
        remoteLog?("resolved pid=\(corr.pid) nonce=\(nonce) action=\(action) won=\(won)")
        if won {
            transport.answerCallbackQuery(id: callback.id, text: decision.verdict == .block ? "Denied" : "Allowed", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: Self.phoneResolvedText(action), completion: nil)
        } else {
            transport.answerCallbackQuery(id: callback.id, text: "Already resolved", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: Self.macResolvedText(.mac), completion: nil)
        }
    }

    private func promptForReply(corr: Correlation, kind: ReplyKind, callbackId: String, chat: Int64) {
        transport.answerCallbackQuery(id: callbackId, text: kind == .allow ? "Reply with a note" : "Reply with a reason", completion: nil)
        let target = corr.toolName.isEmpty ? "this approval" : corr.toolName
        let prompt = kind == .allow ? "Reply with a note approving \(target)…" : "Reply with a reason to deny \(target)…"
        transport.sendForceReply(chatId: chat, text: prompt) { [weak self] result in
            guard let self, case .success(let mid) = result else { return }
            self.lock.lock(); self.promptReplies[mid] = PendingReply(nonce: corr.nonce, kind: kind); self.lock.unlock()
            self.remoteLog?("\(Self.typedReplyAction(kind)) prompt pid=\(corr.pid) nonce=\(corr.nonce) promptMid=\(mid)")
        }
    }

    // MARK: - Helpers

    private func resetBackoff() { lock.lock(); backoff = 1; lock.unlock() }

    private func bumpBackoff() -> TimeInterval {
        lock.lock()
        let current = backoff
        backoff = min(backoff * 2, 60)
        lock.unlock()
        return current * Double.random(in: 0.8...1.2)
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decision(for action: String) -> Decision {
        switch action {
        case "d": return Decision(verdict: .block, reason: "Denied from phone")
        case "c": return Decision(verdict: .block, reason: "Denied from phone — clean up the house-rule comment violations in this change, then re-propose the commit.")
        case "s": return Decision(verdict: .allow, reason: "Approved for session from phone")
        case "g": return Decision(verdict: .allow, reason: "Browsing lease granted from phone")
        default: return Decision(verdict: .allow, reason: "Approved from phone")
        }
    }

    private static func typedReplyDecision(kind: ReplyKind, text: String) -> Decision {
        switch kind {
        case .deny: return Decision(verdict: .block, reason: "Denied from phone — \(text)")
        case .allow: return Decision(verdict: .allow, reason: "Approved from phone", additionalContext: "Approver note from phone: \(text)")
        }
    }

    private static func typedReplyResolvedText(kind: ReplyKind, text: String) -> String {
        switch kind {
        case .deny: return "🛑 Denied from phone — \(text)"
        case .allow: return "✅ Approved from phone — \(text)"
        }
    }

    private static func typedReplyAction(_ kind: ReplyKind) -> String {
        kind == .allow ? "allow-note" : "deny-reason"
    }

    private static func phoneResolvedText(_ action: String) -> String {
        switch action {
        case "d": return "🛑 Denied from phone"
        case "c": return "🧹 Denied — clean comments & re-propose"
        case "g": return "🌐 Site leased from phone"
        default: return "✅ Approved from phone"
        }
    }

    private func forget(_ nonce: String) {
        lock.lock()
        byNonce.removeValue(forKey: nonce)
        pendingOrder.removeAll { $0 == nonce }
        promptReplies = promptReplies.filter { $0.value.nonce != nonce }
        lock.unlock()
    }

    private enum ReplyKind { case allow, deny }

    private struct PendingReply {
        let nonce: String
        let kind: ReplyKind
    }

    private enum TypedReplyTarget {
        case target(Correlation, ReplyKind)
        case ambiguous(Int)
        case none
    }

    private func typedReplyTarget(replyTo: Int?) -> TypedReplyTarget {
        lock.lock(); defer { lock.unlock() }
        if let replyTo {
            if let pending = promptReplies[replyTo], let corr = byNonce[pending.nonce] { return .target(corr, pending.kind) }
            if let match = byNonce.values.first(where: { $0.messageId == replyTo }) { return .target(match, .deny) }
            return .none
        }
        switch pendingOrder.count {
        case 0: return .none
        case 1: return byNonce[pendingOrder[0]].map { .target($0, .deny) } ?? .none
        default: return .ambiguous(pendingOrder.count)
        }
    }

    private func consumeSendToken() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        sendTokens = min(5.0, sendTokens + now.timeIntervalSince(lastRefill))
        lastRefill = now
        guard sendTokens >= 1 else { return false }
        sendTokens -= 1
        return true
    }

    private func coalesce(chat: Int64) {
        lock.lock()
        coalescedCount += 1
        let count = coalescedCount
        let now = Date()
        let shouldNotice = lastCoalesceNotice.map { now.timeIntervalSince($0) > 5 } ?? true
        if shouldNotice { lastCoalesceNotice = now }
        lock.unlock()
        guard shouldNotice else { return }
        transport.sendMessage(chatId: chat, text: "⚠️ \(count) approvals queued too fast for Telegram — answer them on your Mac.", keyboard: nil, completion: { _ in })
    }

    private static func macResolvedText(_ source: ResolvableApproval.Source) -> String {
        source == .timeout ? "⏱ Timed out — denied (Mac)" : "✅ Answered on Mac"
    }

    /// Build the redacted, control-stripped message body for an approval — full command, capped near Telegram's limit.
    static func summaryBody(payload: PreToolUsePayload, session: Session, triggerReason: String?) -> String {
        let label = session.label.isEmpty ? "PID \(session.pid)" : session.label
        var lines = ["Gavel approval — \(sanitizeForDisplay(label))", "Tool: \(payload.toolName)"]
        if let cwd = session.cwd {
            let tail = cwd.split(separator: "/").suffix(2).joined(separator: "/")
            if !tail.isEmpty { lines.append("cwd: …/\(tail)") }
        }
        let raw = payload.command ?? payload.filePath ?? firstStringInput(payload) ?? ""
        if !raw.isEmpty {
            let cleaned = sanitizeForDisplay(SecretRedactor.redact(raw))
            if cleaned.count > GavelConstants.telegramBodyMaxChars {
                lines.append(String(cleaned.prefix(GavelConstants.telegramBodyMaxChars)) + "… (truncated — full on Mac)")
            } else {
                lines.append(cleaned)
            }
        }
        if let reason = triggerReason, !reason.isEmpty { lines.append("(\(sanitizeForDisplay(reason)))") }
        return lines.joined(separator: "\n")
    }

    /// Metadata-only body for a credential-gated approval — names the session so it can be verified in Claude, never the command.
    static func withheldBody(payload: PreToolUsePayload, session: Session) -> String {
        let label = session.label.isEmpty ? "PID \(session.pid)" : session.label
        var lines = ["🔒 Gavel — command withheld", "Session: \(sanitizeForDisplay(label))", "Tool: \(payload.toolName)"]
        if let cwd = session.cwd {
            let tail = cwd.split(separator: "/").suffix(2).joined(separator: "/")
            if !tail.isEmpty { lines.append("cwd: …/\(tail)") }
        }
        lines.append("Sensitive content detected — command not shown. Verify it in the Claude session, then Allow or Deny below.")
        return lines.joined(separator: "\n")
    }

    private static func firstStringInput(_ payload: PreToolUsePayload) -> String? {
        for (_, v) in payload.toolInput { if let s = v.stringValue { return s } }
        return nil
    }

    private static func sanitizeForDisplay(_ text: String) -> String {
        let bidi: Set<UInt32> = [0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\n" { return true }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            return !bidi.contains(scalar.value)
        }))
    }
}
