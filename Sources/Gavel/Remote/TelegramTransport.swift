import Foundation

struct TelegramButton {
    let text: String
    let callbackData: String
}

struct TelegramCallback {
    let id: String
    let fromId: Int64
    let chatId: Int64
    let messageId: Int
    let data: String
}

struct TelegramIncomingMessage {
    let fromId: Int64
    let chatId: Int64
    let text: String?
}

struct TelegramUpdate {
    let updateId: Int
    let callback: TelegramCallback?
    let message: TelegramIncomingMessage?
}

enum TelegramError: Error {
    case http(Int)
    case api(String)
    case malformedResponse
    case unauthorizedToken
}

/// Abstracts the Telegram Bot API so the bridge can be unit-tested against a fake.
protocol TelegramTransport: AnyObject {
    func sendMessage(chatId: Int64, text: String, keyboard: [[TelegramButton]]?, completion: @escaping (Result<Int, Error>) -> Void)
    func editMessageText(chatId: Int64, messageId: Int, text: String, completion: ((Result<Void, Error>) -> Void)?)
    func answerCallbackQuery(id: String, text: String?, completion: ((Result<Void, Error>) -> Void)?)
    func getUpdates(offset: Int, timeoutSeconds: Int, completion: @escaping (Result<[TelegramUpdate], Error>) -> Void)
}
