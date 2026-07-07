import XCTest

@testable import Gavel

final class DiffCaptureTests: XCTestCase {

    // MARK: - Flag detection

    func testAllFlagVariants() {
        XCTAssertTrue(DiffCapture.commitUsesAllFlag("git commit -am 'x'"))
        XCTAssertTrue(DiffCapture.commitUsesAllFlag("git commit -a -m 'x'"))
        XCTAssertTrue(DiffCapture.commitUsesAllFlag("git commit --all -m 'x'"))
        XCTAssertTrue(DiffCapture.commitUsesAllFlag("git commit -qam 'x'"))
        XCTAssertFalse(DiffCapture.commitUsesAllFlag("git commit -m 'x'"))
        XCTAssertFalse(DiffCapture.commitUsesAllFlag("git commit --amend -m 'x'"))
    }

    func testAllFlagNotFooledByMessageContent() {
        XCTAssertFalse(DiffCapture.commitUsesAllFlag(#"git commit -m "docs: explain the -a flag""#))
        XCTAssertFalse(DiffCapture.commitUsesAllFlag("git commit -m 'add -a support later'"))
    }

    // MARK: - Repo dir resolution

    func testRepoDirHonorsDashC() {
        XCTAssertEqual(
            DiffCapture.repoDir(command: "git -C /tmp/scratch commit -m x", fallback: "/repo"),
            "/tmp/scratch")
        XCTAssertEqual(
            DiffCapture.repoDir(command: #"git -C "/tmp/my repo" commit -m x"#, fallback: "/repo"),
            "/tmp/my repo")
        XCTAssertEqual(
            DiffCapture.repoDir(command: "git -C sub/dir commit -m x", fallback: "/repo"),
            "/repo/sub/dir")
        XCTAssertEqual(
            DiffCapture.repoDir(command: "git commit -m x", fallback: "/repo"),
            "/repo")
    }

    func testRepoDirIgnoresDashCInsideMessage() {
        XCTAssertEqual(
            DiffCapture.repoDir(command: #"git commit -m "use -C /elsewhere for git""#, fallback: "/repo"),
            "/repo")
    }

    // MARK: - Message extraction

    func testCommitMessageExtraction() {
        XCTAssertEqual(DiffCapture.commitMessage(from: #"git commit -m "feat: add thing""#), "feat: add thing")
        XCTAssertEqual(DiffCapture.commitMessage(from: "git commit -m 'fix bug'"), "fix bug")
        XCTAssertEqual(DiffCapture.commitMessage(from: "git commit -m oneword"), "oneword")
        XCTAssertNil(DiffCapture.commitMessage(from: "git commit"))
    }

    // MARK: - Live capture against a scratch repo

    private func makeRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-diffcapture-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNotNil(DiffCapture.runGit(["init", "-q"], cwd: dir))
        return dir
    }

    private func write(_ text: String, to name: String, in dir: String) throws {
        try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testCapturesStagedDiff() throws {
        let repo = try makeRepo()
        try write("hello\n", to: "f.txt", in: repo)
        XCTAssertNotNil(DiffCapture.runGit(["add", "f.txt"], cwd: repo))

        let captured = DiffCapture.capture(cwd: repo, command: "git commit -m 'test'")
        XCTAssertNotNil(captured)
        XCTAssertFalse(captured!.includesUnstaged)
        XCTAssertFalse(captured!.truncated)
        XCTAssertTrue(captured!.diffText.contains("+hello"))
        XCTAssertEqual(captured!.commitMessage, "test")

        let files = DiffParser.parse(captured!.diffText)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].displayPath, "f.txt")
        XCTAssertTrue(files[0].isNew)
    }

    func testDashAFallsBackToHeadDiff() throws {
        let repo = try makeRepo()
        try write("v1\n", to: "f.txt", in: repo)
        XCTAssertNotNil(DiffCapture.runGit(["add", "f.txt"], cwd: repo))
        XCTAssertNotNil(DiffCapture.runGit(
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], cwd: repo))
        try write("v2\n", to: "f.txt", in: repo)

        // Plain commit: nothing staged, so the cached diff is empty…
        let staged = DiffCapture.capture(cwd: repo, command: "git commit -m 'x'")
        XCTAssertEqual(DiffParser.parse(staged!.diffText).count, 0)

        // …but -am stages tracked changes at commit time, so review HEAD-relative.
        let all = DiffCapture.capture(cwd: repo, command: "git commit -am 'x'")
        XCTAssertTrue(all!.includesUnstaged)
        XCTAssertTrue(all!.diffText.contains("+v2"))
    }

    func testNonRepoReturnsNil() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-notarepo-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNil(DiffCapture.capture(cwd: dir, command: "git commit -m x"))
    }
}
