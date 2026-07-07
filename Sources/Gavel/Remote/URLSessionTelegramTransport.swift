import Foundation

/// Live Telegram Bot API transport over `URLSession` long-polling. Pure Foundation.
/// The bot token is held privately and never logged.
final class URLSessionTelegramTransport: TelegramTransport {

    private let token: String
    private let session: URLSession

    init(token: String) {
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = TimeInterval(GavelConstants.telegramPollTimeoutSeconds + 15)
        cfg.timeoutIntervalForResource = TimeInterval(GavelConstants.telegramPollTimeoutSeconds + 20)
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Replace the bot token with a placeholder so log lines never leak it.
    func redactToken(_ text: String) -> String {
        text.replacingOccurrences(of: token, with: "‹token›")
    }

    func sendMessage(chatId: Int64, text: String, keyboard: [[TelegramButton]]?, completion: @escaping (Result<Int, Error>) -> Void) {
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "disable_web_page_preview": true
        ]
        if let keyboard { params["reply_markup"] = ["inline_keyboard": encode(keyboard)] }
        call("sendMessage", params: params) { result in
            switch result {
            case .success(let json):
                if let r = json["result"] as? [String: Any], let mid = r["message_id"] as? Int {
                    completion(.success(mid))
                } else {
                    completion(.failure(TelegramError.malformedResponse))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func sendForceReply(chatId: Int64, text: String, completion: @escaping (Result<Int, Error>) -> Void) {
        let params: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "disable_web_page_preview": true,
            "reply_markup": ["force_reply": true, "selective": true]
        ]
        call("sendMessage", params: params) { result in
            switch result {
            case .success(let json):
                if let r = json["result"] as? [String: Any], let mid = r["message_id"] as? Int {
                    completion(.success(mid))
                } else {
                    completion(.failure(TelegramError.malformedResponse))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func editMessageText(chatId: Int64, messageId: Int, text: String, completion: ((Result<Void, Error>) -> Void)?) {
        let params: [String: Any] = [
            "chat_id": chatId,
            "message_id": messageId,
            "text": text,
            "reply_markup": ["inline_keyboard": [[String: Any]]()]
        ]
        call("editMessageText", params: params) { result in
            completion?(result.map { _ in () })
        }
    }

    func answerCallbackQuery(id: String, text: String?, completion: ((Result<Void, Error>) -> Void)?) {
        var params: [String: Any] = ["callback_query_id": id]
        if let text { params["text"] = text }
        call("answerCallbackQuery", params: params) { result in
            completion?(result.map { _ in () })
        }
    }

    func getUpdates(offset: Int, timeoutSeconds: Int, completion: @escaping (Result<[TelegramUpdate], Error>) -> Void) {
        let params: [String: Any] = [
            "offset": offset,
            "timeout": timeoutSeconds,
            "allowed_updates": ["callback_query", "message"]
        ]
        call("getUpdates", params: params) { result in
            switch result {
            case .success(let json):
                guard let array = json["result"] as? [[String: Any]] else {
                    completion(.failure(TelegramError.malformedResponse))
                    return
                }
                completion(.success(array.compactMap { Self.parseUpdate($0) }))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func encode(_ keyboard: [[TelegramButton]]) -> [[[String: String]]] {
        keyboard.map { row in
            row.map { button in
                if let url = button.url {
                    return ["text": button.text, "url": url]
                }
                return ["text": button.text, "callback_data": button.callbackData ?? ""]
            }
        }
    }

    private func call(_ method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            completion(.failure(TelegramError.malformedResponse))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                completion(.failure(TelegramError.unauthorizedToken))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TelegramError.malformedResponse))
                return
            }
            if (json["ok"] as? Bool) == true {
                completion(.success(json))
            } else if (json["error_code"] as? Int) == 429 {
                let retry = (json["parameters"] as? [String: Any])?["retry_after"] as? Double ?? 1
                completion(.failure(TelegramError.rateLimited(retryAfter: retry)))
            } else {
                completion(.failure(TelegramError.api(json["description"] as? String ?? "unknown")))
            }
        }.resume()
    }

    private static func parseUpdate(_ dict: [String: Any]) -> TelegramUpdate? {
        guard let updateId = dict["update_id"] as? Int else { return nil }
        return TelegramUpdate(
            updateId: updateId,
            callback: parseCallback(dict["callback_query"] as? [String: Any]),
            message: parseMessage(dict["message"] as? [String: Any])
        )
    }

    private static func parseCallback(_ dict: [String: Any]?) -> TelegramCallback? {
        guard let dict,
              let id = dict["id"] as? String,
              let from = dict["from"] as? [String: Any],
              let fromId = (from["id"] as? Int64) ?? (from["id"] as? Int).map(Int64.init),
              let message = dict["message"] as? [String: Any],
              let messageId = message["message_id"] as? Int,
              let chat = message["chat"] as? [String: Any],
              let chatId = (chat["id"] as? Int64) ?? (chat["id"] as? Int).map(Int64.init),
              let data = dict["data"] as? String else { return nil }
        return TelegramCallback(id: id, fromId: fromId, chatId: chatId, messageId: messageId, data: data)
    }

    private static func parseMessage(_ dict: [String: Any]?) -> TelegramIncomingMessage? {
        guard let dict,
              let from = dict["from"] as? [String: Any],
              let fromId = (from["id"] as? Int64) ?? (from["id"] as? Int).map(Int64.init),
              let chat = dict["chat"] as? [String: Any],
              let chatId = (chat["id"] as? Int64) ?? (chat["id"] as? Int).map(Int64.init) else { return nil }
        let replyTo = (dict["reply_to_message"] as? [String: Any])?["message_id"] as? Int
        return TelegramIncomingMessage(fromId: fromId, chatId: chatId, text: dict["text"] as? String, replyToMessageId: replyTo)
    }
}
