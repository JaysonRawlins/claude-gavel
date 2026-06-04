import XCTest
@testable import Gavel

final class ConfigIntegrityTests: XCTestCase {
    private var dir: String!
    private var rulesPath: String!
    private var integrity: ConfigIntegrity!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "configintegrity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        rulesPath = dir + "/rules.json"
        FileManager.default.createFile(atPath: rulesPath, contents: Data("{}".utf8))
        integrity = ConfigIntegrity(protectedPaths: [rulesPath])
    }

    override func tearDownWithError() throws {
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for entry in entries { chflags(dir + "/" + entry, 0) }
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func isImmutable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    private func externalWriteSucceeds(_ path: String) -> Bool {
        do {
            try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    func testProtectMakesFileImmutableAndBlocksExternalWrite() {
        integrity.protect()
        XCTAssertTrue(isImmutable(rulesPath), "protected file must carry UF_IMMUTABLE")
        XCTAssertFalse(externalWriteSucceeds(rulesPath), "external write must fail with EPERM once immutable")
    }

    func testWriteWindowAllowsDaemonWriteThenReasserts() {
        integrity.protect()
        var bodyRan = false
        integrity.withWriteWindow(path: rulesPath) {
            bodyRan = true
            try? Data("daemon-write".utf8).write(to: URL(fileURLWithPath: rulesPath))
        }
        XCTAssertTrue(bodyRan, "write-window must run the body")
        XCTAssertEqual(try? String(contentsOfFile: rulesPath, encoding: .utf8), "daemon-write")
        XCTAssertTrue(isImmutable(rulesPath), "immutability must be re-asserted after the window closes")
        XCTAssertFalse(externalWriteSucceeds(rulesPath), "external write blocked again after the window")
    }

    func testUnprotectClearsImmutableAndAllowsWrite() {
        integrity.protect()
        integrity.unprotect()
        XCTAssertFalse(isImmutable(rulesPath))
        XCTAssertTrue(externalWriteSucceeds(rulesPath), "write must succeed once unprotected")
    }

    func testProtectIsIdempotent() {
        integrity.protect()
        integrity.protect()
        XCTAssertTrue(isImmutable(rulesPath))
    }

    func testProtectIgnoresAbsentPath() {
        let absent = ConfigIntegrity(protectedPaths: [dir + "/does-not-exist.json"])
        absent.protect()
        absent.unprotect()
    }

    func testWriteWindowLeavesUnprotectedPathUntouched() {
        let other = dir + "/session-defaults.json"
        FileManager.default.createFile(atPath: other, contents: Data("{}".utf8))
        integrity.withWriteWindow(path: other) {
            try? Data("x".utf8).write(to: URL(fileURLWithPath: other))
        }
        XCTAssertFalse(isImmutable(other), "a path outside the protected set must never be flagged")
    }

    func testSharedSingletonDoesNotFlagTestTempPaths() {
        let temp = dir + "/rules.json"
        ConfigIntegrity.shared.withWriteWindow(path: temp) {
            try? Data("x".utf8).write(to: URL(fileURLWithPath: temp))
        }
        XCTAssertFalse(isImmutable(temp), "the production singleton must not flag temp config used in tests")
    }
}
