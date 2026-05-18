import Foundation
import Darwin

/// Native process-tree utilities via sysctl/proc_pidinfo — replaces shelling out to `ps`, saving ~80ms of subprocess overhead per hook.
struct ProcessTree {
    /// Walk up to 8 hops from `pid` looking for an ancestor whose `p_comm` (case-insensitive) contains `needle`. Returns nil if not found within the hop budget.
    static func findAncestorPid(from pid: Int32, named needle: String) -> Int32? {
        let target = needle.lowercased()
        var current = pid
        for _ in 0..<8 {
            if let name = processName(pid: current),
               name.lowercased().contains(target) {
                return current
            }
            guard let ppid = parentPid(of: current), ppid > 1 else {
                break
            }
            current = ppid
        }
        return nil
    }

    static func findClaudePid(from pid: Int32) -> Int32? {
        findAncestorPid(from: pid, named: "claude")
    }

    static func findCodexPid(from pid: Int32) -> Int32? {
        findAncestorPid(from: pid, named: "codex")
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

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

    static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func enumerateAllPids() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Process table can grow between size-query and data-fetch — pad and accept the resulting partial fill.
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

    /// Kernel-recorded process start time — used to order rehydrated/discovered sessions by when the agent actually started, not when gavel noticed.
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

    /// Discover live CLI sessions whose `p_comm` matches `target` exactly — exact-match (not substring) so we don't pick up helper processes whose truncated paths happen to contain the agent name.
    static func findCliSessions(processName target: String) -> [(pid: Int32, cwd: String)] {
        var results: [(Int32, String)] = []
        for pid in enumerateAllPids() {
            guard let name = processName(pid: pid), name == target else { continue }
            guard let cwd = cwd(of: pid) else { continue }
            results.append((pid, cwd))
        }
        return results
    }

    static func findClaudeCliSessions() -> [(pid: Int32, cwd: String)] {
        findCliSessions(processName: "claude")
    }
}
