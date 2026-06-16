import Foundation
import Security

/// Bridges pending approvals to a Telegram bot and races inbound button taps
/// against the on-Mac panel. Additive: the local panel stays authoritative.
final class RemoteApprovalBridge {

    static weak var shared: RemoteApprovalBridge?

    private final class Correlation {
        let resolvable: ResolvableApproval
        let allowSession: (() -> Void)?
        var messageId: Int?
        init(resolvable: ResolvableApproval, allowSession: (() -> Void)?) {
            self.resolvable = resolvable
            self.allowSession = allowSession
        }
    }

    private let transport: TelegramTransport
    private let redact: (String) -> String
    private let lock = NSLock()
    private var byNonce: [String: Correlation] = [:]
    private var offset = 0
    private var running = false
    private var backoff: TimeInterval = 1
    private var chatId: Int64?

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
    func notify(resolvable: ResolvableApproval, text: String, allowSession: (() -> Void)?) {
        lock.lock(); let chat = chatId; lock.unlock()
        guard let chat else { return }

        let nonce = Self.makeNonce()
        let corr = Correlation(resolvable: resolvable, allowSession: allowSession)
        lock.lock(); byNonce[nonce] = corr; lock.unlock()

        resolvable.addCleanup { [weak self] source, decision in
            guard let self else { return }
            self.lock.lock(); self.byNonce.removeValue(forKey: nonce); let mid = corr.messageId; self.lock.unlock()
            guard source != .telegram else { return }
            if let mid {
                self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(source), completion: nil)
            }
        }

        let keyboard: [[TelegramButton]] = [
            [TelegramButton(text: "✅ Allow once", callbackData: "a:\(nonce)"),
             TelegramButton(text: "🛑 Deny", callbackData: "d:\(nonce)")],
            [TelegramButton(text: "✅ Allow for session", callbackData: "s:\(nonce)")]
        ]
        transport.sendMessage(chatId: chat, text: text, keyboard: keyboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mid):
                self.lock.lock(); corr.messageId = mid; self.lock.unlock()
                if resolvable.isResolved {
                    self.transport.editMessageText(chatId: chat, messageId: mid, text: Self.macResolvedText(.mac), completion: nil)
                    self.lock.lock(); self.byNonce.removeValue(forKey: nonce); self.lock.unlock()
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
        lock.lock(); let paired = chatId != nil; lock.unlock()
        guard !paired, (message.text ?? "").hasPrefix("/start") else { return }
        lock.lock(); chatId = message.chatId; lock.unlock()
        onPaired?(message.chatId)
        transport.sendMessage(
            chatId: message.chatId,
            text: "Gavel paired ✅ — this chat is now the only one that can answer approvals.",
            keyboard: nil,
            completion: { _ in }
        )
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

        lock.lock(); let corr = byNonce.removeValue(forKey: nonce); lock.unlock()
        guard let corr else {
            transport.answerCallbackQuery(id: callback.id, text: "Already resolved", completion: nil)
            transport.editMessageText(chatId: pinned, messageId: callback.messageId, text: "↪️ Already resolved", completion: nil)
            return
        }

        if action == "s" { corr.allowSession?() }
        let won = corr.resolvable.resolve(Self.decision(for: action), from: .telegram)
        if won {
            transport.answerCallbackQuery(id: callback.id, text: action == "d" ? "Denied" : "Allowed", completion: nil)
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
        case "s": return Decision(verdict: .allow, reason: "Approved for session from phone")
        default: return Decision(verdict: .allow, reason: "Approved from phone")
        }
    }

    private static func phoneResolvedText(_ action: String) -> String {
        action == "d" ? "🛑 Denied from phone" : "✅ Approved from phone"
    }

    private static func macResolvedText(_ source: ResolvableApproval.Source) -> String {
        source == .timeout ? "⏱ Timed out — denied (Mac)" : "✅ Answered on Mac"
    }

    /// Build the redacted, truncated, control-stripped message body for an approval.
    static func summaryBody(payload: PreToolUsePayload, session: Session, triggerReason: String?) -> String {
        let label = session.label.isEmpty ? "PID \(session.pid)" : session.label
        let raw = payload.command ?? payload.filePath ?? firstStringInput(payload) ?? ""
        let summary = sanitizeForDisplay(SecretRedactor.redact(raw))
        let capped = summary.count > GavelConstants.telegramSummaryMaxChars
            ? String(summary.prefix(GavelConstants.telegramSummaryMaxChars)) + "…"
            : summary
        var lines = ["Gavel approval — \(sanitizeForDisplay(label))", "Tool: \(payload.toolName)"]
        if !capped.isEmpty { lines.append(capped) }
        if let reason = triggerReason, !reason.isEmpty { lines.append("(\(sanitizeForDisplay(reason)))") }
        lines.append("(full detail on Mac)")
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
