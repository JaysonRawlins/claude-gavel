import XCTest
@testable import Gavel

final class ResolvableApprovalTests: XCTestCase {

    func testFirstResolveWinsSubsequentAreNoOps() {
        var sunk: [Decision] = []
        let approval = ResolvableApproval { sunk.append($0) }

        let firstWon = approval.resolve(Decision(verdict: .allow, reason: "a"), from: .telegram)
        let secondWon = approval.resolve(Decision(verdict: .block, reason: "b"), from: .mac)

        XCTAssertTrue(firstWon)
        XCTAssertFalse(secondWon)
        XCTAssertEqual(sunk.count, 1)
        XCTAssertEqual(sunk.first?.verdict, .allow)
    }

    func testCleanupHookFiresOnceWithWinningSource() {
        let approval = ResolvableApproval { _ in }
        var sources: [ResolvableApproval.Source] = []
        approval.addCleanup { source, _ in sources.append(source) }

        approval.resolve(Decision(verdict: .allow, reason: nil), from: .mac)
        approval.resolve(Decision(verdict: .block, reason: nil), from: .telegram)

        XCTAssertEqual(sources, [.mac])
    }

    func testIsResolvedReflectsState() {
        let approval = ResolvableApproval { _ in }
        XCTAssertFalse(approval.isResolved)
        approval.resolve(Decision(verdict: .allow, reason: nil), from: .timeout)
        XCTAssertTrue(approval.isResolved)
    }

    func testConcurrentResolveYieldsExactlyOneWinner() {
        let approval = ResolvableApproval { _ in }
        let winners = NSMutableArray()
        let group = DispatchGroup()
        for source in [ResolvableApproval.Source.mac, .telegram, .timeout] {
            group.enter()
            DispatchQueue.global().async {
                if approval.resolve(Decision(verdict: .allow, reason: nil), from: source) {
                    objc_sync_enter(winners); winners.add(1); objc_sync_exit(winners)
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(winners.count, 1)
    }
}
