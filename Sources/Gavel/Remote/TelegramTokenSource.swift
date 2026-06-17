import Foundation

/// Where the Telegram bot token is read from (Doppler for dev builds, Keychain for release).
protocol TelegramTokenSource {
    func load() -> String?
}

struct KeychainTokenSource: TelegramTokenSource {
    func load() -> String? { TelegramCredentials.loadToken() }
}

/// Reads the token via the `doppler` CLI using the user's login, so a fresh dev rebuild never prompts.
struct DopplerTokenSource: TelegramTokenSource {
    let project: String
    let config: String
    let secret: String

    func load() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["doppler", "secrets", "get", secret, "-p", project, "-c", config, "--plain"]
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extra)" }) ?? extra
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }
}

enum TelegramTokenResolver {
    static func resolve(executablePath: String? = Bundle.main.executablePath) -> TelegramTokenSource {
        if (executablePath ?? "").contains("/.build/") {
            return DopplerTokenSource(project: "gavel", config: "dev", secret: "TELEGRAM_BOT_TOKEN")
        }
        return KeychainTokenSource()
    }
}
