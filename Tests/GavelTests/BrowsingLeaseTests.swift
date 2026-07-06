import XCTest

@testable import Gavel

final class BrowsingLeaseTests: XCTestCase {

    // Verbatim shape of a real claude-in-chrome response (captured 2026-07-06).
    private let computerResponse = """
        Successfully captured screenshot (1568x748, jpeg) - ID: ss_6893plqd3

        Tab Context:
        - Executed on tabId: 2140008915
        - Available tabs:
          • tabId 2140008915: "Example Domain" (https://example.com/)
        """

    private let driftedResponse = """
        Clicked at (400, 300)

        Tab Context:
        - Executed on tabId: 2140008915
        - Available tabs:
          • tabId 2140008915: "Evil" (https://evil.example.net/phish)
          • tabId 99: "Old tab" (https://example.com/)
        """

    // MARK: - Host normalization

    func testNormalizedHostStripsWwwAndLowercases() {
        XCTAssertEqual(BrowsingLease.normalizedHost(fromURL: "https://WWW.Example.COM/path?q=1"), "example.com")
        XCTAssertEqual(BrowsingLease.normalizedHost(fromURL: "https://example.com"), "example.com")
    }

    func testNormalizedHostAcceptsSchemelessURL() {
        // navigate accepts scheme-less input and defaults to https
        XCTAssertEqual(BrowsingLease.normalizedHost(fromURL: "example.com/login"), "example.com")
    }

    func testNormalizedHostSubdomainIsDistinct() {
        XCTAssertEqual(BrowsingLease.normalizedHost(fromURL: "https://sub.example.com"), "sub.example.com")
    }

    func testNormalizedHostRejectsGarbage() {
        XCTAssertNil(BrowsingLease.normalizedHost(fromURL: ""))
        XCTAssertNil(BrowsingLease.normalizedHost(fromURL: "   "))
    }

    // MARK: - Lease gating

    func testLeaseAllowsComputerAndFormInput() {
        let lease = BrowsingLease(domain: "example.com")
        XCTAssertNotNil(lease.allows(toolName: "mcp__claude-in-chrome__computer", url: nil))
        XCTAssertNotNil(lease.allows(toolName: "mcp__claude-in-chrome__form_input", url: nil))
    }

    func testLeaseNeverAllowsExfilGradeTools() {
        let lease = BrowsingLease(domain: "example.com")
        for tool in ["javascript_tool", "file_upload", "upload_image", "shortcuts_execute", "tabs_create_mcp", "tabs_close_mcp"] {
            XCTAssertNil(
                lease.allows(toolName: "mcp__claude-in-chrome__\(tool)", url: nil),
                "\(tool) must keep its normal prompt tier under a lease")
        }
    }

    func testLeaseAllowsSameSiteNavigateOnly() {
        let lease = BrowsingLease(domain: "example.com")
        XCTAssertNotNil(lease.allows(toolName: BrowsingLease.navigateTool, url: "https://example.com/page2"))
        XCTAssertNotNil(lease.allows(toolName: BrowsingLease.navigateTool, url: "www.example.com/page3"))
        XCTAssertNil(lease.allows(toolName: BrowsingLease.navigateTool, url: "https://other.com"))
        XCTAssertNil(lease.allows(toolName: BrowsingLease.navigateTool, url: nil))
    }

    func testExpiredLeaseAllowsNothing() {
        let lease = BrowsingLease(domain: "example.com", grantedAt: Date(timeIntervalSinceNow: -3600), ttl: 60)
        XCTAssertFalse(lease.isActive)
        XCTAssertNil(lease.allows(toolName: "mcp__claude-in-chrome__computer", url: nil))
    }

    func testLeaseIgnoresNonChromeTools() {
        let lease = BrowsingLease(domain: "example.com")
        XCTAssertNil(lease.allows(toolName: "Bash", url: nil))
        XCTAssertNil(lease.allows(toolName: "Write", url: nil))
    }

    // MARK: - Drift detection

    func testExecutedTabURLParsesRealResponse() {
        XCTAssertEqual(BrowsingLease.executedTabURL(inResponse: computerResponse), "https://example.com/")
    }

    func testExecutedTabURLPicksExecutedTabNotOthers() {
        XCTAssertEqual(BrowsingLease.executedTabURL(inResponse: driftedResponse), "https://evil.example.net/phish")
    }

    func testNoDriftOnLeasedDomain() {
        XCTAssertNil(BrowsingLease.driftReason(inResponse: computerResponse, domain: "example.com"))
    }

    func testDriftRevokesOnForeignDomain() {
        let reason = BrowsingLease.driftReason(inResponse: driftedResponse, domain: "example.com")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("evil.example.net"))
    }

    func testDriftFailsClosedOnUnparseableResponse() {
        XCTAssertNotNil(BrowsingLease.driftReason(inResponse: "no tab context here", domain: "example.com"))
        XCTAssertNotNil(BrowsingLease.driftReason(inResponse: "", domain: "example.com"))
    }

    func testTitleWithParenthesesDoesNotBreakURLParse() {
        let response = """
            Tab Context:
            - Executed on tabId: 7
            - Available tabs:
              • tabId 7: "Docs (v2) — reference (beta)" (https://example.com/docs)
            """
        XCTAssertEqual(BrowsingLease.executedTabURL(inResponse: response), "https://example.com/docs")
    }

    // MARK: - Session lifecycle

    func testGrantAndRevokeOnSession() {
        let session = Session(pid: 4242)
        XCTAssertNil(session.browsingLease)
        session.grantBrowsingLease(domain: "example.com")
        XCTAssertEqual(session.browsingLease?.domain, "example.com")
        XCTAssertTrue(session.browsingLease!.isActive)
        let revoked = session.revokeBrowsingLease()
        XCTAssertEqual(revoked?.domain, "example.com")
        XCTAssertNil(session.browsingLease)
    }

    func testRevokeAutoApproveClearsLease() {
        let session = Session(pid: 4243)
        session.grantBrowsingLease(domain: "example.com")
        session.revokeAutoApprove()
        XCTAssertNil(session.browsingLease)
    }

    // MARK: - Response text extraction (MCP content arrays)

    func testExtractResponseTextFromMCPContentDict() {
        let response = AnyCodable([
            "content": AnyCodable([
                AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("hello")]),
                AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("Tab Context: ...")]),
            ])
        ])
        XCTAssertEqual(HookRouter.extractResponseText(response), "hello\nTab Context: ...")
    }

    func testExtractResponseTextFromBashDict() {
        let response = AnyCodable([
            "stdout": AnyCodable("out"),
            "stderr": AnyCodable("err"),
        ])
        XCTAssertEqual(HookRouter.extractResponseText(response), "out\nerr")
    }

    func testExtractResponseTextFromPlainString() {
        XCTAssertEqual(HookRouter.extractResponseText(AnyCodable("plain")), "plain")
    }

    func testExtractResponseTextFromBareArray() {
        let response = AnyCodable([
            AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("item")])
        ])
        XCTAssertEqual(HookRouter.extractResponseText(response), "item")
    }
}
