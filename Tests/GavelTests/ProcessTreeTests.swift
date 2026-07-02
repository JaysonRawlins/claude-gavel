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
        // Pick a PID that's almost certainly not allocated.
        XCTAssertNil(ProcessTree.cwd(of: 999_999))
    }

    func testFindClaudeCliSessionsReturnsValidShape() {
        // Doesn't assume Claude is running — just that the call returns
        // without crashing and that any results look well-formed.
        let sessions = ProcessTree.findClaudeCliSessions()
        for (pid, cwd) in sessions {
            XCTAssertGreaterThan(pid, 0)
            XCTAssertFalse(cwd.isEmpty)
            XCTAssertTrue(cwd.hasPrefix("/"))
        }
    }

    // MARK: - Executable path matching

    func testExecutablePathOfSelf() {
        guard let path = ProcessTree.executablePath(pid: getpid()) else {
            XCTFail("executablePath failed for our own PID")
            return
        }
        XCTAssertTrue(path.hasPrefix("/"))
    }

    func testPathHasComponentMatchesVersionNamedInstall() {
        XCTAssertTrue(ProcessTree.pathHasComponent(
            "/Users/u/.local/share/claude/versions/2.1.198", matching: "claude"))
    }

    func testPathHasComponentRejectsSubstringComponents() {
        XCTAssertFalse(ProcessTree.pathHasComponent(
            "/Users/u/code/claude-gavel/.build/release/gavel", matching: "claude"))
        XCTAssertFalse(ProcessTree.pathHasComponent(
            "/Applications/Claude.app/Contents/Helpers/chrome-native-host", matching: "claude"))
    }

    func testPathHasDirectoryComponentExcludesBasename() {
        // Claude Desktop's binary basename lowercases to "claude" but its
        // install dirs don't — must not be discovered as a CLI session.
        XCTAssertFalse(ProcessTree.pathHasDirectoryComponent(
            "/Applications/Claude.app/Contents/MacOS/Claude", matching: "claude"))
        // Ancestor attribution intentionally does match on basename.
        XCTAssertTrue(ProcessTree.pathHasComponent(
            "/Applications/Claude.app/Contents/MacOS/Claude", matching: "claude"))
    }

    func testPathHasDirectoryComponentMatchesInstallDir() {
        XCTAssertTrue(ProcessTree.pathHasDirectoryComponent(
            "/Users/u/.local/share/claude/versions/2.1.198", matching: "claude"))
        XCTAssertTrue(ProcessTree.pathHasDirectoryComponent(
            "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", matching: "claude"))
        XCTAssertFalse(ProcessTree.pathHasDirectoryComponent(
            "/Users/u/code/claude-gavel/versions/2.1.198", matching: "claude"))
    }

    // MARK: - Live discovery fixtures
    //
    // Copies real binaries into a version-named directory layout mirroring the
    // native Claude install (…/claude/versions/9.9.9), spawns them, and runs
    // actual discovery against the live process table.

    private var fixtureRoot: URL!
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gavel-ptree-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        for proc in spawned where proc.isRunning { proc.terminate() }
        spawned = []
        if let root = fixtureRoot {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    /// Copy /bin/sleep to fixtureRoot/<relativePath> and spawn it.
    private func spawnFixture(_ relativePath: String) throws -> Process {
        let dest = fixtureRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: dest)
        let proc = Process()
        proc.executableURL = dest
        proc.arguments = ["30"]
        proc.currentDirectoryURL = fixtureRoot
        try proc.run()
        spawned.append(proc)
        return proc
    }

    private func discoveredPids() -> Set<Int32> {
        Set(ProcessTree.findCliSessions(processName: "claude").map(\.pid))
    }

    func testDiscoversVersionNamedBinaryInClaudeDir() throws {
        let proc = try spawnFixture("claude/versions/9.9.9")
        let sessions = ProcessTree.findCliSessions(processName: "claude")
        guard let match = sessions.first(where: { $0.pid == proc.processIdentifier }) else {
            XCTFail("version-named binary under a claude/ dir was not discovered")
            return
        }
        let expectedCwd = (fixtureRoot.path as NSString).resolvingSymlinksInPath
        XCTAssertEqual((match.cwd as NSString).resolvingSymlinksInPath, expectedCwd)
    }

    func testDoesNotDiscoverVersionNamedBinaryOutsideClaudeDir() throws {
        let proc = try spawnFixture("claude-gavel/versions/9.9.9")
        XCTAssertFalse(discoveredPids().contains(proc.processIdentifier))
    }

    func testDoesNotDiscoverUppercaseClaudeBasename() throws {
        // Mirrors Claude Desktop: p_comm "Claude" ≠ "claude", and the basename
        // must not satisfy the directory-component fallback.
        let proc = try spawnFixture("desktop/Claude")
        XCTAssertFalse(discoveredPids().contains(proc.processIdentifier))
    }

    // MARK: - Wrapper dedupe

    func testDropWrapperParentsKeepsOnlyLeafProcesses() {
        // Mirrors the live ClaudeCode.app chain: cc-daemon (100) → pty-host
        // (200) → REPL (300); plus a terminal session (400) whose parent is a
        // non-candidate shell.
        let candidates: [(pid: Int32, cwd: String)] = [
            (100, "/w"), (200, "/w"), (300, "/w"), (400, "/t"),
        ]
        let parents: [Int32: Int32] = [200: 100, 300: 200, 400: 999]
        let kept = ProcessTree.dropWrapperParents(candidates) { parents[$0] }
        XCTAssertEqual(kept.map(\.pid), [300, 400])
    }

    func testDropWrapperParentsHandlesUnknownParents() {
        let candidates: [(pid: Int32, cwd: String)] = [(500, "/a"), (600, "/b")]
        let kept = ProcessTree.dropWrapperParents(candidates) { _ in nil }
        XCTAssertEqual(kept.map(\.pid), [500, 600])
    }

    func testLiveClaudeSessionDiscoveryAgainstPsWitness() throws {
        // Independent witness: `ps` comm paths. Native-install claude
        // processes exec via ~/.local/bin/claude or …/share/claude/… — the
        // exact class findClaudeCliSessions() must discover. Skips when no
        // claude is running (CI).
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var witnesses: [(pid: Int32, ppid: Int32)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  fields[2].contains("/.local/bin/claude") || fields[2].contains("/.local/share/claude/")
            else { continue }
            witnesses.append((pid, ppid))
        }
        try XCTSkipIf(witnesses.isEmpty, "no native-install claude processes running")

        let witnessPids = Set(witnesses.map(\.pid))
        let wrapperPids = Set(witnesses.map(\.ppid)).intersection(witnessPids)
        let leaves = witnessPids.subtracting(wrapperPids)
        let discovered = discoveredPids()

        for pid in leaves where ProcessTree.isAlive(pid: pid) && ProcessTree.cwd(of: pid) != nil {
            XCTAssertTrue(discovered.contains(pid),
                          "live claude session pid \(pid) was not discovered")
        }
        for pid in wrapperPids {
            XCTAssertFalse(discovered.contains(pid),
                           "wrapper pid \(pid) should not be discovered as a session")
        }
    }
}
