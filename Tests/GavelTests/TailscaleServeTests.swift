import XCTest

@testable import Gavel

final class TailscaleServeTests: XCTestCase {

    private var savedRunner: ((_ binary: String, _ args: [String]) -> (status: Int32, stdout: String)?)!
    private var savedSockets: (() -> [String])!

    override func setUpWithError() throws {
        try XCTSkipIf(TailscaleServe.candidateBinaries().isEmpty, "no tailscale CLI installed")
        savedRunner = TailscaleServe.runner
        savedSockets = TailscaleServe.socketPaths
    }

    override func tearDown() {
        if savedRunner != nil { TailscaleServe.runner = savedRunner }
        if savedSockets != nil { TailscaleServe.socketPaths = savedSockets }
    }

    private func statusJSON(state: String, dns: String?, iosPeerOnline: Bool? = nil) -> String {
        let selfBlock = dns.map { #""Self": {"DNSName": "\#($0)"},"# } ?? ""
        let peerBlock = iosPeerOnline.map {
            #""Peer": {"nodekey:abc": {"OS": "iOS", "Online": \#($0)}, "nodekey:def": {"OS": "linux", "Online": true}},"#
        } ?? ""
        return #"{"BackendState": "\#(state)", \#(selfBlock) \#(peerBlock) "Version": "1.98"}"#
    }

    private func socketArg(in args: [String]) -> String? {
        args.first { $0.hasPrefix("--socket=") }
    }

    // MARK: - Status parsing

    func testBackendStripsTrailingDotAndKeepsSocket() {
        let backend = TailscaleServe.backend(
            binary: "/bin/ts", socketPath: "/var/run/tailscaled-x.sock",
            statusJSON: Data(statusJSON(state: "Running", dns: "mac.tail1234.ts.net.").utf8))
        XCTAssertEqual(backend?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(backend?.socketPath, "/var/run/tailscaled-x.sock")
        XCTAssertEqual(backend?.hasOnlineIOSPeer, false)
    }

    func testStoppedBackendYieldsNil() {
        XCTAssertNil(TailscaleServe.backend(
            binary: "/bin/ts", socketPath: nil,
            statusJSON: Data(statusJSON(state: "Stopped", dns: "mac.tail1234.ts.net.").utf8)))
    }

    func testMissingSelfOrGarbageYieldsNil() {
        XCTAssertNil(TailscaleServe.backend(
            binary: "/bin/ts", socketPath: nil,
            statusJSON: Data(statusJSON(state: "Running", dns: nil).utf8)))
        XCTAssertNil(TailscaleServe.backend(
            binary: "/bin/ts", socketPath: nil, statusJSON: Data("not json".utf8)))
    }

    func testDetectsOnlineIOSPeer() {
        let online = TailscaleServe.backend(
            binary: "/bin/ts", socketPath: nil,
            statusJSON: Data(statusJSON(state: "Running", dns: "a.ts.net.", iosPeerOnline: true).utf8))
        XCTAssertEqual(online?.hasOnlineIOSPeer, true)

        let offline = TailscaleServe.backend(
            binary: "/bin/ts", socketPath: nil,
            statusJSON: Data(statusJSON(state: "Running", dns: "a.ts.net.", iosPeerOnline: false).utf8))
        XCTAssertEqual(offline?.hasOnlineIOSPeer, false)
    }

    // MARK: - Endpoint discovery + backend choice

    /// The dogfood topology: GUI extension Stopped, custom-socket daemon
    /// Running with the phone online. The socket endpoint must win, and
    /// serve must be registered through the same socket.
    func testCustomSocketDaemonChosenOverStoppedExtension() {
        TailscaleServe.socketPaths = { ["/var/run/tailscaled-personal.sock"] }
        var serveCalls: [[String]] = []
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                if self.socketArg(in: args) != nil {
                    return (0, self.statusJSON(state: "Running", dns: "personal.tail2.ts.net.", iosPeerOnline: true))
                }
                return (0, self.statusJSON(state: "Stopped", dns: "work.tail1.ts.net."))
            }
            serveCalls.append(args)
            return (0, "")
        }

        let base = TailscaleServe.reviewBaseURL()
        XCTAssertEqual(base, "https://personal.tail2.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        XCTAssertEqual(serveCalls.count, 1)
        XCTAssertEqual(socketArg(in: serveCalls[0]), "--socket=/var/run/tailscaled-personal.sock")
        XCTAssertEqual(Array(serveCalls[0].dropFirst()), [
            "serve", "--bg",
            "--https=\(GavelConstants.reviewTailnetHTTPSPort)",
            "http://127.0.0.1:\(GavelConstants.reviewServerPort)",
        ])
    }

    func testBothRunningPrefersBackendWithOnlineIOSPeer() {
        TailscaleServe.socketPaths = { ["/var/run/tailscaled-personal.sock"] }
        var serveCalls: [[String]] = []
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                if self.socketArg(in: args) != nil {
                    return (0, self.statusJSON(state: "Running", dns: "personal.tail2.ts.net.", iosPeerOnline: false))
                }
                return (0, self.statusJSON(state: "Running", dns: "work.tail1.ts.net.", iosPeerOnline: true))
            }
            serveCalls.append(args)
            return (0, "")
        }

        let base = TailscaleServe.reviewBaseURL()
        XCTAssertEqual(base, "https://work.tail1.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        XCTAssertNil(socketArg(in: serveCalls[0]), "serve must go through the same (default) endpoint as the chosen backend")
    }

    func testBothRunningNoPhoneFallsBackToSocketEndpoint() {
        TailscaleServe.socketPaths = { ["/var/run/tailscaled-personal.sock"] }
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                if self.socketArg(in: args) != nil {
                    return (0, self.statusJSON(state: "Running", dns: "personal.tail2.ts.net.", iosPeerOnline: false))
                }
                return (0, self.statusJSON(state: "Running", dns: "work.tail1.ts.net.", iosPeerOnline: false))
            }
            return (0, "")
        }
        // Socket endpoints are probed first, so with no phone anywhere the
        // explicitly-configured daemon wins.
        XCTAssertEqual(
            TailscaleServe.reviewBaseURL(),
            "https://personal.tail2.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
    }

    func testSameNodeReachedTwiceIsDeduped() {
        TailscaleServe.socketPaths = { [] }
        var serveCalls = 0
        // Every default-discovery probe (one per installed binary) reports
        // the same node — must collapse to one backend, one serve call.
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                return (0, self.statusJSON(state: "Running", dns: "solo.tail1.ts.net.", iosPeerOnline: true))
            }
            serveCalls += 1
            return (0, "")
        }
        XCTAssertEqual(
            TailscaleServe.reviewBaseURL(),
            "https://solo.tail1.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        XCTAssertEqual(serveCalls, 1)
    }

    func testAllStoppedFailsSoft() {
        TailscaleServe.socketPaths = { ["/var/run/tailscaled-personal.sock"] }
        var serveCalls = 0
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                return (0, self.statusJSON(state: "Stopped", dns: "x.ts.net."))
            }
            serveCalls += 1
            return (0, "")
        }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
        XCTAssertEqual(serveCalls, 0)
    }

    func testServeFailureIncludingTimeoutFailsSoft() {
        TailscaleServe.socketPaths = { [] }
        TailscaleServe.runner = { _, args in
            if args.contains("--json") {
                return (0, self.statusJSON(state: "Running", dns: "x.ts.net."))
            }
            // 124 is the runner's timeout status — the blocked "Serve is not
            // enabled" interactive wait surfaces this way.
            return (124, "Serve is not enabled on your tailnet.")
        }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }

    func testNoRunnableBinariesFailsSoft() {
        TailscaleServe.socketPaths = { [] }
        TailscaleServe.runner = { _, _ in nil }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }

    // MARK: - Serve-disabled enable URL

    func testEnableURLExtraction() {
        let output = """

        Serve is not enabled on your tailnet.
        To enable, visit:

        \thttps://login.tailscale.com/f/serve?node=nABC123CNTRL
        """
        XCTAssertEqual(
            TailscaleServe.enableURL(fromServeOutput: output),
            "https://login.tailscale.com/f/serve?node=nABC123CNTRL")
        XCTAssertNil(TailscaleServe.enableURL(fromServeOutput: "some other failure"))
        XCTAssertEqual(
            TailscaleServe.enableURL(fromServeOutput: "Serve is not enabled on your tailnet."),
            "https://login.tailscale.com")
    }
}
