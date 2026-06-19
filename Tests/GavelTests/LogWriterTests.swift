import XCTest
@testable import Gavel

/// Hammers LogWriter from many threads to prove serialized appends drop or tear no lines.
final class LogWriterTests: XCTestCase {

    private var path = ""

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "logwriter-\(UUID().uuidString).log"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testConcurrentAppendsDropNoLines() {
        let writer = LogWriter(path: path)
        let threads = 16
        let perThread = 500
        let total = threads * perThread

        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                writer.append("thread=\(t) seq=\(i)\n")
            }
        }

        let contents = try! String(contentsOfFile: path, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, total, "expected every appended line to survive")

        var seen = Set<String>()
        for line in lines {
            XCTAssertTrue(
                line.range(of: #"^thread=\d+ seq=\d+$"#, options: .regularExpression) != nil,
                "torn or interleaved line: \(line)"
            )
            seen.insert(String(line))
        }
        XCTAssertEqual(seen.count, total, "expected every line to be unique and present")
    }
}
