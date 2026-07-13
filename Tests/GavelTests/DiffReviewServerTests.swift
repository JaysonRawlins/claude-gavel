import XCTest

@testable import Gavel

final class DiffReviewServerTests: XCTestCase {

    private var server: DiffReviewServer!
    private var port: UInt16!

    override func setUpWithError() throws {
        server = DiffReviewServer()
        try server.start(port: 0)
        port = try XCTUnwrap(server.boundPort)
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    // MARK: - Helpers

    private func makeContent(diff: String = defaultDiff) -> ReviewContent {
        ReviewContent(
            repoName: "scratch-repo",
            commitMessage: "feat: test",
            files: DiffParser.parse(diff),
            includesUnstaged: false,
            truncated: false)
    }

    private static let defaultDiff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -10,3 +10,4 @@ struct A {
     context
    -old
    +new
    +extra
    """

    private struct HTTPResult {
        let status: Int
        let body: String
    }

    private func request(_ path: String, method: String = "GET", body: String? = nil) throws -> HTTPResult {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        req.httpMethod = method
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: HTTPResult?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = HTTPResult(
                    status: http.statusCode,
                    body: String(decoding: data ?? Data(), as: UTF8.self))
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 10) == .success else {
            throw XCTSkip("HTTP request timed out")
        }
        return try XCTUnwrap(result)
    }

    // MARK: - GET

    func testGetRendersDiff() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertEqual(res.status, 200)
        XCTAssertTrue(res.body.contains("Sources/A.swift"))
        XCTAssertTrue(res.body.contains("+new"))
        XCTAssertTrue(res.body.contains("scratch-repo"))
    }

    func testLocalURLServesTheRegisteredPage() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let localURL = try XCTUnwrap(server.localURL(nonce: nonce))
        XCTAssertEqual(localURL, "http://127.0.0.1:\(port!)/review/\(nonce)")

        let res = try request("/review/\(nonce)")
        XCTAssertEqual(res.status, 200)
    }

    func testUnknownNonceIs404() throws {
        let res = try request("/review/does-not-exist")
        XCTAssertEqual(res.status, 404)
        XCTAssertFalse(res.body.contains("Sources"))
    }

    func testUnknownRouteIs404() throws {
        let res = try request("/anything/else")
        XCTAssertEqual(res.status, 404)
    }

    // MARK: - POST verdict

    func testRequestChangesBlocksWithComments() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let body = """
        {"verdict":"request_changes","note":"tighten this up",
         "comments":[{"file":"Sources/A.swift","line":10,"text":"rename this"},
                     {"file":"Sources/A.swift","line":12,"text":"guard nil first"}]}
        """
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
        XCTAssertEqual(res.status, 200)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .block)
        let reason = try XCTUnwrap(d.reason)
        XCTAssertTrue(reason.contains("changes requested (2 comments)"))
        XCTAssertTrue(reason.contains("Sources/A.swift:10 — rename this"))
        XCTAssertTrue(reason.contains("Sources/A.swift:12 — guard nil first"))
        XCTAssertTrue(reason.contains("Overall: tighten this up"))
    }

    func testApproveWithNoteAllowsWithContext() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let body = #"{"verdict":"approve","note":"nice","comments":[]}"#
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: body)
        XCTAssertEqual(res.status, 200)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .allow)
        XCTAssertEqual(d.additionalContext?.contains("Overall: nice"), true)
    }

    func testApproveWithoutCommentsHasNoContext() {
        let d = DiffReviewServer.decision(
            for: ReviewVerdictSubmission(verdict: "approve", note: nil, comments: []))
        XCTAssertEqual(d?.verdict, .allow)
        XCTAssertNil(d?.additionalContext)
    }

    func testUnknownVerdictRejected() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"maybe"}"#)
        XCTAssertEqual(res.status, 400)
        XCTAssertNil(decision)
        XCTAssertFalse(resolvable.isResolved)
    }

    func testMalformedBodyRejected() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let res = try request("/review/\(nonce)/verdict", method: "POST", body: "not json {{{")
        XCTAssertEqual(res.status, 400)
        XCTAssertNil(decision)
    }

    // MARK: - Resolution lifecycle

    func testSecondSubmitIs409AndGetShowsResolved() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let first = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"approve"}"#)
        XCTAssertEqual(first.status, 200)

        let second = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"approve"}"#)
        XCTAssertEqual(second.status, 409)

        let page = try request("/review/\(nonce)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.body.contains("Already resolved"))
        XCTAssertFalse(page.body.contains("+new"), "resolved page must not leak diff content")
    }

    func testWebLosesRaceToMacPanel() throws {
        var decisions: [Decision] = []
        let resolvable = ResolvableApproval { decisions.append($0) }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        // Mac panel wins first…
        XCTAssertTrue(resolvable.resolve(Decision(verdict: .allow, reason: "panel"), from: .mac))

        // …web submit afterwards is a conflict, and no second Decision fires.
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"request_changes"}"#)
        XCTAssertEqual(res.status, 409)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].reason, "panel")

        let page = try request("/review/\(nonce)")
        XCTAssertTrue(page.body.contains("Mac panel"))
    }

    // MARK: - Reviewed signal

    func testViewedPageThenMacAllowCarriesReviewedSignal() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        _ = try request("/review/\(nonce)")
        resolvable.resolve(Decision(verdict: .allow, reason: "User approved"), from: .mac)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(
            d.additionalContext,
            "User approved this via Gavel — user reviewed the diff before approving")
    }

    func testMacAllowWithoutViewHasNoReviewedSignal() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        _ = server.register(content: makeContent(), resolvable: resolvable)

        resolvable.resolve(Decision(verdict: .allow, reason: "User approved"), from: .mac)

        let d = try XCTUnwrap(decision)
        XCTAssertNil(d.additionalContext, "approved-on-trust must not claim a review")
    }

    func testReviewedSignalAppendsToExistingNote() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        _ = try request("/review/\(nonce)")
        resolvable.resolve(
            Decision(
                verdict: .allow, reason: "User approved",
                additionalContext: "User approved this via Gavel — commit gate"),
            from: .telegram)

        let ctx = try XCTUnwrap(decision?.additionalContext)
        XCTAssertTrue(ctx.hasPrefix("User approved this via Gavel — commit gate"))
        XCTAssertTrue(ctx.hasSuffix("User reviewed the diff before approving."))
    }

    func testWebApproveAfterViewCarriesReviewedSignal() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        _ = try request("/review/\(nonce)")
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: #"{"verdict":"approve"}"#)
        XCTAssertEqual(res.status, 200)

        let d = try XCTUnwrap(decision)
        XCTAssertEqual(d.verdict, .allow)
        XCTAssertEqual(
            d.additionalContext,
            "User approved this via Gavel — user reviewed the diff before approving")
    }

    func testViewedPageThenDenyGetsNoSignal() throws {
        var decision: Decision?
        let resolvable = ResolvableApproval { decision = $0 }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        _ = try request("/review/\(nonce)")
        resolvable.resolve(Decision(verdict: .block, reason: "User denied"), from: .mac)

        let d = try XCTUnwrap(decision)
        XCTAssertNil(d.additionalContext)
    }

    // MARK: - Credential withholding

    func testHunkWithKnownSecretIsWithheld() throws {
        let secretDiff = """
        diff --git a/config.env b/config.env
        index 1111111..2222222 100644
        --- a/config.env
        +++ b/config.env
        @@ -1,1 +1,2 @@
         KEY=old
        +AWS_KEY=AKIAIOSFODNN7EXAMPLE
        """
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(content: makeContent(diff: secretDiff), resolvable: resolvable)

        let res = try request("/review/\(nonce)")
        XCTAssertEqual(res.status, 200)
        XCTAssertFalse(res.body.contains("AKIAIOSFODNN7EXAMPLE"), "secret must never be served")
        XCTAssertTrue(res.body.contains("withheld"))
        XCTAssertTrue(res.body.contains("AWS access key"))
    }

    // MARK: - Oversize body

    func testOversizedBodyRejected() throws {
        let resolvable = ResolvableApproval { _ in }
        let nonce = server.register(content: makeContent(), resolvable: resolvable)

        let huge = #"{"verdict":"approve","note":""# + String(repeating: "x", count: GavelConstants.reviewMaxBodyBytes + 1024) + #""}"#
        let res = try request("/review/\(nonce)/verdict", method: "POST", body: huge)
        XCTAssertEqual(res.status, 413)
        XCTAssertFalse(resolvable.isResolved)
    }
}
