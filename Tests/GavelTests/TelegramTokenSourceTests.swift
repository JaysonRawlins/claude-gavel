import XCTest
@testable import Gavel

final class TelegramTokenSourceTests: XCTestCase {

    func testDevBuildPathResolvesToDoppler() {
        let source = TelegramTokenResolver.resolve(executablePath: "/Users/jay/code/claude-gavel/.build/release/gavel")
        XCTAssertTrue(source is DopplerTokenSource)
    }

    func testBrewBuildPathResolvesToKeychain() {
        let source = TelegramTokenResolver.resolve(executablePath: "/opt/homebrew/Cellar/gavel/1.24.0/bin/gavel")
        XCTAssertTrue(source is KeychainTokenSource)
    }

    func testNilPathResolvesToKeychain() {
        XCTAssertTrue(TelegramTokenResolver.resolve(executablePath: nil) is KeychainTokenSource)
    }
}
