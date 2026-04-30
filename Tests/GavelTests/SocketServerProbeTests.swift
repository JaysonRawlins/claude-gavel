import XCTest
import Darwin
@testable import Gavel

final class SocketServerProbeTests: XCTestCase {

    private func tempSocketPath() -> String {
        let dir = NSTemporaryDirectory()
        let name = "gavel-probe-\(UUID().uuidString.prefix(8)).sock"
        return (dir as NSString).appendingPathComponent(name)
    }

    func testProbeFalseWhenNoSocketFile() {
        let path = tempSocketPath()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(SocketServer.probeAlive(socketPath: path))
    }

    func testProbeTrueWhileServerListening() throws {
        let path = tempSocketPath()
        defer { unlink(path) }

        let server = SocketServer(socketPath: path)
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(SocketServer.probeAlive(socketPath: path))
    }

    func testProbeFalseAfterServerStops() throws {
        let path = tempSocketPath()
        defer { unlink(path) }

        let server = SocketServer(socketPath: path)
        try server.start()
        XCTAssertTrue(SocketServer.probeAlive(socketPath: path))

        server.stop()
        XCTAssertFalse(SocketServer.probeAlive(socketPath: path))
    }

    func testProbeFalseOnStaleSocketFile() throws {
        // Simulate the case where a daemon crashed: socket file lingers, but
        // no listener is bound. probeAlive should return false (ECONNREFUSED).
        let path = tempSocketPath()
        defer { unlink(path) }

        // Create a socket file via bind, then close the fd without listening.
        // Connect attempts to this path will fail with ECONNREFUSED.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() { dest[i] = byte }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        close(fd) // No listen() call → file exists but no listener.

        XCTAssertFalse(SocketServer.probeAlive(socketPath: path))
    }

    func testStartRefusesWhenPeerAlive() throws {
        let path = tempSocketPath()
        defer { unlink(path) }

        let serverA = SocketServer(socketPath: path)
        try serverA.start()
        defer { serverA.stop() }

        let serverB = SocketServer(socketPath: path)
        XCTAssertThrowsError(try serverB.start()) { error in
            guard case GavelError.daemonAlreadyRunning(let p) = error else {
                XCTFail("Expected daemonAlreadyRunning, got \(error)")
                return
            }
            XCTAssertEqual(p, path)
        }
    }
}
