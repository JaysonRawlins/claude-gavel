import XCTest
@testable import Gavel

final class CredentialGateTests: XCTestCase {

    private func payload(_ input: [String: Any]) -> PreToolUsePayload {
        PreToolUsePayload(toolName: "Bash", toolInput: input.mapValues { AnyCodable($0) })
    }

    func testAwsKeyBlocks() {
        XCTAssertTrue(CredentialGate.blocksRemote(payload(["command": "aws s3 ls AKIAIOSFODNN7EXAMPLE"])))
    }

    func testGitHubPatBlocks() {
        XCTAssertTrue(CredentialGate.blocksRemote(payload(["command": "echo ghp_0123456789abcdefABCDEF0123456789abcdef"])))
    }

    func testGenericHighEntropyRunBlocks() {
        XCTAssertTrue(CredentialGate.blocksRemote(payload(["command": "export TOKEN=Xa9Kd2Lp8Qw3Zr7Tv1Bn6Mc"])))
    }

    func testNestedInputFieldIsScanned() {
        let nested: [String: Any] = ["env": ["SECRET": "AKIAIOSFODNN7EXAMPLE"]]
        XCTAssertTrue(CredentialGate.blocksRemote(payload(nested)))
    }

    func testPlainCommandPasses() {
        XCTAssertFalse(CredentialGate.blocksRemote(payload(["command": "swift build && swift test"])))
    }

    func testUuidIsNotCredentialShaped() {
        XCTAssertFalse(CredentialGate.blocksRemote(payload(["command": "open 1d17c7c4-5cc5-4eda-a03f-a029b5254345"])))
    }

    func testIsoTimestampIsNotCredentialShaped() {
        XCTAssertFalse(CredentialGate.blocksRemote(payload(["command": "log since 2026-06-16T11:09:00"])))
    }

    func testFilesystemPathIsNotCredentialShaped() {
        XCTAssertFalse(CredentialGate.blocksRemote(payload(["file_path": "/Users/jay/code/Sources/Gavel/main.swift"])))
    }
}
