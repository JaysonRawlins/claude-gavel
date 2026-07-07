import XCTest

@testable import Gavel

final class TailscaleServeTests: XCTestCase {

    private var savedRunner: ((_ binary: String, _ args: [String]) -> (status: Int32, stdout: String)?)!

    override func setUp() {
        savedRunner = TailscaleServe.runner
    }

    override func tearDown() {
        TailscaleServe.runner = savedRunner
    }

    private func statusJSON(state: String, dns: String?, iosPeerOnline: Bool? = nil) -> String {
        let selfBlock = dns.map { #""Self": {"DNSName": "\#($0)"},"# } ?? ""
        let peerBlock = iosPeerOnline.map {
            #""Peer": {"nodekey:abc": {"OS": "iOS", "Online": \#($0)}, "nodekey:def": {"OS": "linux", "Online": true}},"#
        } ?? ""
        return #"{"BackendState": "\#(state)", \#(selfBlock) \#(peerBlock) "Version": "1.98"}"#
    }

    // MARK: - Status parsing

    func testBackendStripsTrailingDot() {
        let backend = TailscaleServe.backend(
            binary: "/bin/ts",
            statusJSON: Data(statusJSON(state: "Running", dns: "mac.tail1234.ts.net.").utf8))
        XCTAssertEqual(backend?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(backend?.hasOnlineIOSPeer, false)
    }

    func testStoppedBackendYieldsNil() {
        XCTAssertNil(TailscaleServe.backend(
            binary: "/bin/ts",
            statusJSON: Data(statusJSON(state: "Stopped", dns: "mac.tail1234.ts.net.").utf8)))
    }

    func testMissingSelfOrGarbageYieldsNil() {
        XCTAssertNil(TailscaleServe.backend(
            binary: "/bin/ts", statusJSON: Data(statusJSON(state: "Running", dns: nil).utf8)))
        XCTAssertNil(TailscaleServe.backend(binary: "/bin/ts", statusJSON: Data("not json".utf8)))
    }

    func testDetectsOnlineIOSPeer() {
        let online = TailscaleServe.backend(
            binary: "/bin/ts",
            statusJSON: Data(statusJSON(state: "Running", dns: "a.ts.net.", iosPeerOnline: true).utf8))
        XCTAssertEqual(online?.hasOnlineIOSPeer, true)

        let offline = TailscaleServe.backend(
            binary: "/bin/ts",
            statusJSON: Data(statusJSON(state: "Running", dns: "a.ts.net.", iosPeerOnline: false).utf8))
        XCTAssertEqual(offline?.hasOnlineIOSPeer, false)
    }

    // MARK: - Backend choice + serve registration

    /// Stub a fleet of backends: binary path → status JSON (or nil for "can't run").
    /// Serve calls succeed and are recorded.
    private func stubBackends(_ fleet: [String: String?], serveCalls: NSMutableArray) {
        TailscaleServe.runner = { binary, args in
            if args.first == "status" {
                guard let json = fleet[binary] ?? nil else { return nil }
                return (0, json)
            }
            serveCalls.add([binary] + args)
            return (0, "")
        }
    }

    func testSingleRunningBackendIsUsed() {
        let serveCalls = NSMutableArray()
        // Only probe binaries that exist on this machine — candidateBinaries()
        // filters by executability, so stub every candidate uniformly.
        var fleet: [String: String?] = [:]
        for (index, binary) in TailscaleServe.candidateBinaries().enumerated() {
            fleet[binary] = index == 0
                ? statusJSON(state: "Running", dns: "solo.tail1.ts.net.")
                : statusJSON(state: "Stopped", dns: "other.tail2.ts.net.")
        }
        try? XCTSkipIf(fleet.isEmpty, "no tailscale binaries installed")
        stubBackends(fleet, serveCalls: serveCalls)

        let base = TailscaleServe.reviewBaseURL()
        XCTAssertEqual(base, "https://solo.tail1.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        XCTAssertEqual(serveCalls.count, 1)
        let call = serveCalls[0] as! [String]
        XCTAssertEqual(Array(call.dropFirst()), [
            "serve", "--bg",
            "--https=\(GavelConstants.reviewTailnetHTTPSPort)",
            "http://127.0.0.1:\(GavelConstants.reviewServerPort)",
        ])
    }

    func testTwoRunningBackendsPrefersOnlineIOSPeer() throws {
        let candidates = TailscaleServe.candidateBinaries()
        try XCTSkipIf(candidates.count < 2, "needs two installed tailscale binaries")

        let serveCalls = NSMutableArray()
        var fleet: [String: String?] = [:]
        // First candidate running but phoneless; second running WITH the phone.
        fleet[candidates[0]] = statusJSON(state: "Running", dns: "work.tail1.ts.net.", iosPeerOnline: false)
        fleet[candidates[1]] = statusJSON(state: "Running", dns: "personal.tail2.ts.net.", iosPeerOnline: true)
        for extra in candidates.dropFirst(2) { fleet[extra] = nil }
        stubBackends(fleet, serveCalls: serveCalls)

        let base = TailscaleServe.reviewBaseURL()
        XCTAssertEqual(base, "https://personal.tail2.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        // Serve must be registered through the SAME backend the URL points at.
        XCTAssertEqual((serveCalls[0] as! [String]).first, candidates[1])
    }

    func testTwoRunningBackendsNoPhoneFallsBackToFirst() throws {
        let candidates = TailscaleServe.candidateBinaries()
        try XCTSkipIf(candidates.count < 2, "needs two installed tailscale binaries")

        let serveCalls = NSMutableArray()
        var fleet: [String: String?] = [:]
        fleet[candidates[0]] = statusJSON(state: "Running", dns: "first.tail1.ts.net.", iosPeerOnline: false)
        fleet[candidates[1]] = statusJSON(state: "Running", dns: "second.tail2.ts.net.", iosPeerOnline: false)
        for extra in candidates.dropFirst(2) { fleet[extra] = nil }
        stubBackends(fleet, serveCalls: serveCalls)

        XCTAssertEqual(
            TailscaleServe.reviewBaseURL(),
            "https://first.tail1.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
    }

    func testAllStoppedFailsSoft() {
        let serveCalls = NSMutableArray()
        var fleet: [String: String?] = [:]
        for binary in TailscaleServe.candidateBinaries() {
            fleet[binary] = statusJSON(state: "Stopped", dns: "x.ts.net.")
        }
        stubBackends(fleet, serveCalls: serveCalls)

        XCTAssertNil(TailscaleServe.reviewBaseURL())
        XCTAssertEqual(serveCalls.count, 0)
    }

    func testServeRegistrationFailureFailsSoft() throws {
        try XCTSkipIf(TailscaleServe.candidateBinaries().isEmpty, "no tailscale binaries installed")
        TailscaleServe.runner = { _, args in
            if args.first == "status" {
                return (0, self.statusJSON(state: "Running", dns: "x.ts.net."))
            }
            return (1, "")
        }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }

    func testNoRunnableBinariesFailsSoft() {
        TailscaleServe.runner = { _, _ in nil }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }
}
