import Foundation
import Security

/// Bridges pending approvals to a Telegram bot and races inbound button taps
/// against the on-Mac panel. Additive: the local panel stays authoritative.
final class RemoteApprovalBridge {

    static weak var shared: RemoteApprovalBridge?

    private final class Correlation {
        let nonce: String
        let resolvable: ResolvableApproval
        let allowSession: (() -> Void)?
        var messageId: Int?
        init(nonce: String, resolvable: ResolvableApproval, allowSession: (() -> Void)?) {
            self.nonce = nonce
            self.resolvable = resolvable
            self.allowSession = allowSession
        }
    }

    private let transport: TelegramTransport
    private let redact: (String) -> String
    private let lock = NSLock()
    private var byNonce: [String: Correlation] = [:]
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
    /// Emits a token-redacted status line for the feed/log.
    var onStatus: ((String) -> Void)?

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
    func notify(resolvable: ResolvableApproval, text: String, allowSession: (() -> Void)?, offerCommentClean: Bool = false) {
        lock.lock(); let chat = chatId; lock.unlock()
        guard let chat else { return }

        guard consumeSendToken() else {
            coalesce(chat: chat)
            return
        }

        let nonce = Self.makeNonce()
        let corr = Correlation(nonce: nonce, resolvable: resolvable, allowSession: allowSession)
        lock.lock(); byNonce[nonce] = corr; pendingOrder.append(nonce); lock.unlock()

        resolvable.addCleanup { [weak self] source, _ in
            guard let self else { return }
            self.lock.lock(); let mid = corr.messageId; self.lock.unlock()
            self.forget(nonce)
            guard source != .telegram else { return }
            if let mid {
                self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(source), completion: nil)
            }
        }

        var keyboard: [[TelegramButton]] = [
            [TelegramButton(text: "✅ Allow once", callbackData: "a:\(nonce)"),
             TelegramButton(text: "🛑 Deny", callbackData: "d:\(nonce)")],
            [TelegramButton(text: "✅ Allow for session", callbackData: "s:\(nonce)")]
        ]
        if offerCommentClean {
            keyboard.append([TelegramButton(text: "🧹 Clean comments & re-propose", callbackData: "c:\(nonce)")])
        }
        transport.sendMessage(chatId: chat, text: text, keyboard: keyboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mid):
                self.lock.lock(); corr.messageId = mid; self.lock.unlock()
                if resolvable.isResolved {
                    self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(.mac), completion: nil)
                    self.forget(nonce)
                }
            case .failure(let error):
                self.onStatus?("Telegram send failed: \(self.redact("\(error)"))")
            }
        }
    }

    /// Send a contentless notice that an approval was withheld by the credential gate.
    func notifyWithheld() {
        lock.lock(); let chat = chatId; lock.unlock()
        guard let chat else { return }
        transport.sendMessage(
            chatId: chat,
            text: "🔒 Gavel: an approval was withheld from Telegram (sensitive content detected). Answer it on your Mac.",
            keyboard: nil,
            completion: { _ in }
        )
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
        switch typedReplyTarget(replyTo: message.replyToMessageId) {
        case .target(let corr):
            forget(corr.nonce)
            let decision = Decision(verdict: .block, reason: "Denied from phone — \(text)")
            if corr.resolvable.resolve(decision, from: .telegram), let mid = corr.messageId {
                transport.editMessageText(chatId: pinned, messageId: mid, text: "🛑 Denied from phone — \(text)", completion: nil)
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
        forget(nonce)

        if action == "s" { corr.allowSession?() }
        let decision = Self.decision(for: action)
        let won = corr.resolvable.resolve(decision, from: .telegram)
        if won {
            transport.answerCallbackQuery(id: callback.id, text: decision.verdict == .block ? "Denied" : "Allowed", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: Self.phoneResolvedText(action), completion: nil)
        } else {
            transport.answerCallbackQuery(id: callback.id, text: "Already resolved", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: Self.macResolvedText(.mac), completion: nil)
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
        default: return Decision(verdict: .allow, reason: "Approved from phone")
        }
    }

    private static func phoneResolvedText(_ action: String) -> String {
        switch action {
        case "d": return "🛑 Denied from phone"
        case "c": return "🧹 Denied — clean comments & re-propose"
        default: return "✅ Approved from phone"
        }
    }

    private func forget(_ nonce: String) {
        lock.lock()
        byNonce.removeValue(forKey: nonce)
        pendingOrder.removeAll { $0 == nonce }
        lock.unlock()
    }

    private enum TypedReplyTarget {
        case target(Correlation)
        case ambiguous(Int)
        case none
    }

    private func typedReplyTarget(replyTo: Int?) -> TypedReplyTarget {
        lock.lock(); defer { lock.unlock() }
        if let replyTo {
            if let match = byNonce.values.first(where: { $0.messageId == replyTo }) { return .target(match) }
            return .none
        }
        switch pendingOrder.count {
        case 0: return .none
        case 1: return byNonce[pendingOrder[0]].map { .target($0) } ?? .none
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
