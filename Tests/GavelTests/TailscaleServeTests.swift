import XCTest

@testable import Gavel

final class TailscaleServeTests: XCTestCase {

    private var savedRunner: ((_ args: [String]) -> (status: Int32, stdout: String)?)!

    override func setUp() {
        savedRunner = TailscaleServe.runner
    }

    override func tearDown() {
        TailscaleServe.runner = savedRunner
    }

    private func statusJSON(state: String, dns: String?) -> String {
        let selfBlock = dns.map { #""Self": {"DNSName": "\#($0)"},"# } ?? ""
        return #"{"BackendState": "\#(state)", \#(selfBlock) "Version": "1.98"}"#
    }

    // MARK: - Status parsing

    func testHostnameStripsTrailingDot() {
        let host = TailscaleServe.hostname(
            fromStatusJSON: Data(statusJSON(state: "Running", dns: "mac.tail1234.ts.net.").utf8))
        XCTAssertEqual(host, "mac.tail1234.ts.net")
    }

    func testStoppedBackendYieldsNoHostname() {
        let host = TailscaleServe.hostname(
            fromStatusJSON: Data(statusJSON(state: "Stopped", dns: "mac.tail1234.ts.net.").utf8))
        XCTAssertNil(host)
    }

    func testMissingSelfYieldsNoHostname() {
        XCTAssertNil(TailscaleServe.hostname(
            fromStatusJSON: Data(statusJSON(state: "Running", dns: nil).utf8)))
        XCTAssertNil(TailscaleServe.hostname(fromStatusJSON: Data("not json".utf8)))
    }

    // MARK: - URL construction + serve registration

    func testReviewBaseURLRegistersServeAndBuildsURL() {
        var calls: [[String]] = []
        let status = statusJSON(state: "Running", dns: "mac.tail1234.ts.net.")
        TailscaleServe.runner = { args in
            calls.append(args)
            return args.first == "status" ? (0, status) : (0, "")
        }

        let base = TailscaleServe.reviewBaseURL()
        XCTAssertEqual(base, "https://mac.tail1234.ts.net:\(GavelConstants.reviewTailnetHTTPSPort)")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], ["status", "--json"])
        XCTAssertEqual(calls[1], [
            "serve", "--bg",
            "--https=\(GavelConstants.reviewTailnetHTTPSPort)",
            "http://127.0.0.1:\(GavelConstants.reviewServerPort)",
        ])
    }

    func testStoppedTailscaleFailsSoft() {
        TailscaleServe.runner = { args in
            (0, args.first == "status" ? self.statusJSON(state: "Stopped", dns: "x.ts.net.") : "")
        }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }

    func testServeRegistrationFailureFailsSoft() {
        TailscaleServe.runner = { args in
            if args.first == "status" {
                return (0, self.statusJSON(state: "Running", dns: "x.ts.net."))
            }
            return (1, "")
        }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }

    func testMissingBinaryFailsSoft() {
        TailscaleServe.runner = { _ in nil }
        XCTAssertNil(TailscaleServe.reviewBaseURL())
    }
}
