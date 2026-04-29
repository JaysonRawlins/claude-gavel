import Foundation
import Darwin

/// Native macOS process tree utilities.
///
/// Uses sysctl/proc_pidinfo instead of shelling out to `ps`,
/// eliminating ~80ms of subprocess overhead per hook invocation.
struct ProcessTree {

    /// Walk up the process tree from the given PID to find the Claude Code process.
    /// Returns the Claude PID if found, nil otherwise.
    static func findClaudePid(from pid: Int32) -> Int32? {
        var current = pid
        for _ in 0..<8 {
            if let name = processName(pid: current),
               name.lowercased().contains("claude") {
                return current
            }
            guard let ppid = parentPid(of: current), ppid > 1 else {
                break
            }
            current = ppid
        }
        return nil
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

    /// Discover live Claude Code CLI sessions on the system. Matches on the
    /// short process name `claude` (the CLI sets p_comm to that), which
    /// excludes the Electron desktop app helpers — their p_comm is the
    /// truncated `/Applications/Cl…` binary path.
    static func findClaudeCliSessions() -> [(pid: Int32, cwd: String)] {
        var results: [(Int32, String)] = []
        for pid in enumerateAllPids() {
            guard let name = processName(pid: pid), name == "claude" else { continue }
            guard let cwd = cwd(of: pid) else { continue }
            results.append((pid, cwd))
        }
        return results
    }
}
