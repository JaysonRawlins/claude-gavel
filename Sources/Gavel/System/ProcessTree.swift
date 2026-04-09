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
}
