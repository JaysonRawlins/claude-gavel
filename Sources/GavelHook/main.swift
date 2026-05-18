import Foundation

// gavel-hook — thin CLI shim that reads agent stdin, posts an envelope to the daemon socket, and translates the verdict back to the agent's expected format (stdout JSON+exit 0 for allow, stderr reason+exit 2 for block).
// Fail-closed if the daemon is reachable but returns garbage; fail-open only when the daemon isn't running at all (so Claude works without gavel).

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/gavel/gavel.sock").path

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

var hookType = "PreToolUse"
var stdinJson: [String: Any]?

if let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
    stdinJson = json
    if let name = json["hook_event_name"] as? String {
        hookType = name
    }
}

// Env/argv override — backward-compat with the older bash shims.
if let envType = ProcessInfo.processInfo.environment["CLAUDE_HOOK_TYPE"] {
    hookType = envType
} else if CommandLine.arguments.count > 1 {
    hookType = CommandLine.arguments[1]
}

let needsResponse = hookType == "PreToolUse" || hookType == "PermissionRequest"

// Codex stdin carries `turn_id` (Claude doesn't) — use as the caller discriminator and walk the process tree for the right ancestor.
let isCodexAgent = stdinJson?["turn_id"] != nil
let timestamp = Date().timeIntervalSince1970
let pid = getppid()
let sessionPid: Int32 = isCodexAgent
    ? (findAgentPid(from: pid, named: "codex") ?? pid)
    : (findAgentPid(from: pid, named: "claude") ?? pid)

var envelope: [String: Any] = [
    "hookType": hookType,
    "sessionPid": Int(sessionPid),
    "agent": isCodexAgent ? "codex" : "claude",
    "timestamp": timestamp,
]

if var payload = stdinJson {
    payload["type"] = hookType
    envelope["payload"] = payload
}

guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
    // Can't even build envelope — fail closed.
    if needsResponse { printBlock("Gavel: failed to serialize hook envelope") }
    exit(needsResponse ? 2 : 0)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    // No socket created — kernel resource issue, not gavel-related. Fail open.
    if needsResponse { printAllow() }
    exit(0)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
    close(fd)
    if needsResponse { printBlock("Gavel: socket path too long") }
    exit(needsResponse ? 2 : 0)
}
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (i, byte) in pathBytes.enumerated() {
            dest[i] = byte
        }
    }
}

let connectResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connectResult == 0 else {
    close(fd)
    // Daemon not running — fail OPEN so Claude works without gavel.
    if needsResponse { printAllow() }
    exit(0)
}

envelopeData.withUnsafeBytes { ptr in
    _ = write(fd, ptr.baseAddress!, envelopeData.count)
}

if needsResponse {
    shutdown(fd, SHUT_WR)

    var response = Data()
    let bufSize = 4096
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }

    var timeout = timeval(tv_sec: 86400, tv_usec: 0) // 24h — effectively no timeout; the user is the deadline.
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    while true {
        let n = read(fd, buf, bufSize)
        if n <= 0 { break }
        response.append(buf, count: n)
    }
    close(fd)

    // Daemon response shapes: {"verdict":"allow|block",...} or {} (passthrough — let Claude handle it).
    if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
        if json.isEmpty {
            print("{}")
            exit(0)
        }

        guard let verdict = json["verdict"] as? String else {
            // Has fields but no verdict — treat as passthrough.
            print("{}")
            exit(0)
        }
        if verdict == "block" {
            let reason = (json["reason"] as? String) ?? "Blocked by Gavel"
            printBlock(reason)
            exit(2)
        }

        if hookType == "PermissionRequest" {
            printPermissionAllow()
            exit(0)
        }

        // Codex's PreToolUseHookSpecificOutputWire accepts hookEventName + additionalContext only — permissionDecision and updatedInput are rejected (user edits on Codex silently drop; UI gates them agent-side).
        var output: [String: Any] = ["hookEventName": "PreToolUse"]
        if let ctx = json["additionalContext"] as? String, !ctx.isEmpty {
            output["additionalContext"] = ctx
        }
        if !isCodexAgent {
            output["permissionDecision"] = "allow"
            if let updated = json["updatedInput"] as? [String: Any] {
                output["updatedInput"] = updated
            }
        }
        let wrapper: [String: Any] = ["hookSpecificOutput": output]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper),
           let str = String(data: data, encoding: .utf8) {
            print(str)
            exit(0)
        }
    }

    // Daemon was reachable but its response was empty/unparseable — FAIL CLOSED so the user can debug instead of getting silent allow.
    printBlock("Gavel: daemon returned invalid response")
    exit(2)
} else {
    close(fd)
}

func printAllow() {
    print(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#)
}

func printPermissionAllow() {
    print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
}

func printBlock(_ reason: String) {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
}

func findAgentPid(from startPid: Int32, named needle: String) -> Int32? {
    let target = needle.lowercased()
    var current = startPid
    for _ in 0..<8 {
        if let name = processName(pid: current),
           name.lowercased().contains(target) {
            return current
        }
        guard let ppid = parentPid(of: current), ppid > 1 else { break }
        current = ppid
    }
    return nil
}

func parentPid(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
}

func processName(pid: Int32) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cstr in
            String(cString: cstr)
        }
    }
}
