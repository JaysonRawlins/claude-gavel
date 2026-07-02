import Foundation
import Darwin

/// Native macOS process tree utilities.
///
/// Uses sysctl/proc_pidinfo instead of shelling out to `ps`,
/// eliminating ~80ms of subprocess overhead per hook invocation.
struct ProcessTree {

    /// Walk up the process tree from `pid` looking for an ancestor whose
    /// short process name (case-insensitive) contains `needle`. Returns
    /// that PID or nil after 8 hops. Used to attribute hook calls back
    /// to their owning agent process.
    static func findAncestorPid(from pid: Int32, named needle: String) -> Int32? {
        let target = needle.lowercased()
        var current = pid
        for _ in 0..<8 {
            if let name = processName(pid: current),
               name.lowercased().contains(target) {
                return current
            }
            // Native-install agent binaries are version-named files
            // (…/claude/versions/2.1.198), so p_comm is the version string and
            // the name check above never matches. Match an exact path COMPONENT
            // of the executable instead — component equality, not substring, so
            // paths like …/claude-gavel/… can't false-positive.
            if let path = executablePath(pid: current),
               pathHasComponent(path, matching: target) {
                return current
            }
            guard let ppid = parentPid(of: current), ppid > 1 else {
                break
            }
            current = ppid
        }
        return nil
    }

    /// Convenience wrapper preserved for existing call sites.
    static func findClaudePid(from pid: Int32) -> Int32? {
        findAncestorPid(from: pid, named: "claude")
    }

    /// Codex's hook subprocess is spawned directly by the codex binary, so the
    /// immediate parent already matches — but we still walk a few hops to be
    /// resilient to wrapper scripts.
    static func findCodexPid(from pid: Int32) -> Int32? {
        findAncestorPid(from: pid, named: "codex")
    }

    /// Get the parent PID of a process using sysctl.
    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Get the process name using sysctl.
    static func processName(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        return withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cstr in
                String(cString: cstr)
            }
        }
    }

    /// Check if a process is alive.
    static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Enumerate every process ID on the system via sysctl(KERN_PROC_ALL).
    static func enumerateAllPids() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // sysctl can grow between the size query and the data fetch — pad and retry once.
        var buffer = [UInt8](repeating: 0, count: size + 4096)
        var actualSize = buffer.count
        let result = buffer.withUnsafeMutableBufferPointer { ptr in
            sysctl(&mib, 4, ptr.baseAddress, &actualSize, nil, 0)
        }
        guard result == 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = actualSize / stride
        var pids: [Int32] = []
        pids.reserveCapacity(count)
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let proc = base.advanced(by: i * stride)
                    .assumingMemoryBound(to: kinfo_proc.self).pointee
                let pid = proc.kp_proc.p_pid
                if pid > 0 { pids.append(pid) }
            }
        }
        return pids
    }

    /// Return the kernel-recorded start time of `pid`. Used to order rehydrated
    /// or discovered sessions by when their Claude Code process actually started,
    /// not when gavel happened to notice them.
    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard bytes > 0 else { return nil }
        let secs = TimeInterval(info.pbi_start_tvsec)
        let micros = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: secs + micros)
    }

    /// Return the current working directory of `pid`, using proc_pidinfo
    /// (the same API `lsof` uses internally for `cwd`). Nil if the process
    /// is gone or we lack permission to inspect it.
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard bytes > 0 else { return nil }

        return withUnsafePointer(to: info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    /// Path of the executable image backing `pid`, via proc_pidpath.
    /// Resolves to the real vnode path, so a symlink launch
    /// (~/.local/bin/claude → …/versions/2.1.198) reports the target.
    static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// True if any path component equals `target` (case-insensitive).
    /// Component equality, not substring, so …/claude-gavel/… can't
    /// false-positive against "claude".
    static func pathHasComponent(_ path: String, matching target: String) -> Bool {
        path.lowercased().split(separator: "/").contains(Substring(target.lowercased()))
    }

    /// True if a DIRECTORY component of `path` equals `target` (case-insensitive).
    /// Excludes the basename: Claude Desktop's binary is
    /// /Applications/Claude.app/Contents/MacOS/Claude, whose basename lowercases
    /// to "claude" — only the install-directory component identifies the CLI.
    static func pathHasDirectoryComponent(_ path: String, matching target: String) -> Bool {
        path.lowercased().split(separator: "/").dropLast().contains(Substring(target.lowercased()))
    }

    /// Discover live CLI sessions for the agent named `target`.
    ///
    /// A process matches when its `p_comm` equals `target` exactly, or — for
    /// native-install binaries that are version-named files
    /// (…/claude/versions/2.1.198, p_comm "2.1.198") — when a directory
    /// component of its executable path equals `target`. Exact matches only
    /// (no substring) so helper processes can't false-positive.
    ///
    /// Wrapper processes that exec the agent as a direct child (the
    /// ClaudeCode.app pty-host, the cc-daemon) match too; only the leaf
    /// process is the session, so candidates that are direct parents of
    /// other candidates are dropped.
    static func findCliSessions(processName target: String) -> [(pid: Int32, cwd: String)] {
        var candidates: [(pid: Int32, cwd: String)] = []
        for pid in enumerateAllPids() {
            guard let name = processName(pid: pid) else { continue }
            if name != target {
                guard let path = executablePath(pid: pid),
                      pathHasDirectoryComponent(path, matching: target) else { continue }
            }
            guard let cwd = cwd(of: pid) else { continue }
            candidates.append((pid, cwd))
        }
        return dropWrapperParents(candidates)
    }

    /// Drop candidates that are direct parents of other candidates — a wrapper
    /// (pty-host, cc-daemon) that spawned the real REPL as its child isn't
    /// itself a session. `parentOf` is injectable for tests.
    static func dropWrapperParents(
        _ candidates: [(pid: Int32, cwd: String)],
        parentOf: (Int32) -> Int32? = ProcessTree.parentPid(of:)
    ) -> [(pid: Int32, cwd: String)] {
        let wrapperPids = Set(candidates.compactMap { parentOf($0.pid) })
        return candidates.filter { !wrapperPids.contains($0.pid) }
    }

    /// Convenience wrapper preserved for existing call sites.
    static func findClaudeCliSessions() -> [(pid: Int32, cwd: String)] {
        findCliSessions(processName: "claude")
    }
}
