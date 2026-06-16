import Foundation
@testable import Gavel

final class FakeTelegramTransport: TelegramTransport {
    var sentMessages: [(chatId: Int64, text: String, keyboard: [[TelegramButton]]?)] = []
    var edits: [(messageId: Int, text: String)] = []
    var answers: [(id: String, text: String?)] = []
    private var nextMessageId = 100

    func sendMessage(chatId: Int64, text: String, keyboard: [[TelegramButton]]?, completion: @escaping (Result<Int, Error>) -> Void) {
        sentMessages.append((chatId, text, keyboard))
        let mid = nextMessageId
        nextMessageId += 1
        completion(.success(mid))
    }

    func editMessageText(chatId: Int64, messageId: Int, text: String, completion: ((Result<Void, Error>) -> Void)?) {
        edits.append((messageId, text))
        completion?(.success(()))
    }

    func answerCallbackQuery(id: String, text: String?, completion: ((Result<Void, Error>) -> Void)?) {
        answers.append((id, text))
        completion?(.success(()))
    }

    func getUpdates(offset: Int, timeoutSeconds: Int, completion: @escaping (Result<[TelegramUpdate], Error>) -> Void) {
        parkedUpdatesCompletion = completion
    }

    var parkedUpdatesCompletion: ((Result<[TelegramUpdate], Error>) -> Void)?

    var lastCallbackData: [String] {
        (sentMessages.last?.keyboard ?? []).flatMap { $0 }.map { $0.callbackData }
    }

    var lastSentMessageId: Int { nextMessageId - 1 }
}
