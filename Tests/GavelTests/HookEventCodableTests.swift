import XCTest
@testable import Gavel

final class HookEventCodableTests: XCTestCase {

    private func decodeValue(_ jsonFragment: String) -> AnyCodable? {
        let data = Data("{\"k\":\(jsonFragment)}".utf8)
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)["k"]
    }

    private func encodeRoundTrip(_ value: AnyCodable) -> AnyCodable? {
        guard let data = try? JSONEncoder().encode(["k": value]) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)["k"]
    }

    // MARK: - AnyCodable decode paths

    func testDecodesDouble() {
        XCTAssertEqual(decodeValue("3.14")?.value as? Double, 3.14)
    }

    func testDecodesInt() {
        XCTAssertEqual(decodeValue("42")?.intValue, 42)
    }

    func testDecodesArrayOfMixedTypes() {
        guard let array = decodeValue("[1, \"two\", true]")?.value as? [AnyCodable] else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0].intValue, 1)
        XCTAssertEqual(array[1].stringValue, "two")
        XCTAssertEqual(array[2].boolValue, true)
    }

    func testDecodesNull() {
        XCTAssertTrue(decodeValue("null")?.value is NSNull)
    }

    func testAccessorsReturnNilOnTypeMismatch() {
        XCTAssertNil(decodeValue("\"hello\"")?.intValue)
        XCTAssertNil(decodeValue("42")?.stringValue)
        XCTAssertNil(decodeValue("42")?.boolValue)
    }

    // MARK: - AnyCodable encode round-trip

    func testEncodeRoundTripDouble() {
        XCTAssertEqual(encodeRoundTrip(AnyCodable(3.14))?.value as? Double, 3.14)
    }

    func testEncodeRoundTripNull() {
        XCTAssertTrue(encodeRoundTrip(AnyCodable(NSNull()))?.value is NSNull)
    }

    // MARK: - PreToolUsePayload computed properties

    func testFilePathFromFileKey() {
        let payload = PreToolUsePayload(toolName: "Write", toolInput: ["file_path": AnyCodable("/tmp/a")])
        XCTAssertEqual(payload.filePath, "/tmp/a")
    }

    func testFilePathFallsBackToPathKey() {
        let payload = PreToolUsePayload(toolName: "Write", toolInput: ["path": AnyCodable("/tmp/b")])
        XCTAssertEqual(payload.filePath, "/tmp/b")
    }

    func testFilePathNilWhenNeitherKeyPresent() {
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("ls")])
        XCTAssertNil(payload.filePath)
    }

    func testCommandFromCommandKey() {
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable("ls -la")])
        XCTAssertEqual(payload.command, "ls -la")
    }

    func testIsSubAgentTrueWhenAgentIdPresent() {
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: [:], agentId: "agent-1")
        XCTAssertTrue(payload.isSubAgent)
    }

    func testIsSubAgentFalseWhenAgentIdAbsent() {
        let payload = PreToolUsePayload(toolName: "Bash", toolInput: [:])
        XCTAssertFalse(payload.isSubAgent)
    }
}
