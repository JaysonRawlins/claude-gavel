import XCTest
import Darwin
@testable import Gavel

final class ProcessTreeTests: XCTestCase {
    func testEnumerateAllPidsIncludesSelf() {
        let pids = ProcessTree.enumerateAllPids()
        XCTAssertGreaterThan(pids.count, 1)
        XCTAssertTrue(pids.contains(getpid()))
    }

    func testCwdOfSelfMatchesFileManager() {
        guard let cwd = ProcessTree.cwd(of: getpid()) else {
            XCTFail("cwd lookup failed for our own PID")
            return
        }
        let resolvedActual = (cwd as NSString).resolvingSymlinksInPath
        let resolvedExpected = (FileManager.default.currentDirectoryPath as NSString).resolvingSymlinksInPath
        XCTAssertEqual(resolvedActual, resolvedExpected)
    }

    func testCwdOfNonExistentPidIsNil() {
        XCTAssertNil(ProcessTree.cwd(of: 999_999))
    }

    func testFindClaudeCliSessionsReturnsValidShape() {
        let sessions = ProcessTree.findClaudeCliSessions()
        for (pid, cwd) in sessions {
            XCTAssertGreaterThan(pid, 0)
            XCTAssertFalse(cwd.isEmpty)
            XCTAssertTrue(cwd.hasPrefix("/"))
        }
    }
}
