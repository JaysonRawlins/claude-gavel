import Foundation

/// gavel-hook — Thin CLI shim for Claude Code hooks.
///
/// Reads hook input from stdin, wraps it with metadata, sends it to the
/// Gavel daemon via Unix socket, and translates the response to Claude Code's
/// expected format:
///   - allow → stdout structured hookSpecificOutput JSON, exit 0
///   - block → stderr "reason", exit 2
///
/// SECURITY: If the daemon IS reachable but returns no/unparseable response,
/// fail CLOSED (block). Only fail open when the daemon isn't running at all,
/// so Claude works without gavel.

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/gavel/gavel.sock").path

// stderr is preserved by the bash shim — we write deny reasons there.

// Read stdin
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// Determine hook type: prefer JSON field, fall back to env/argv
var hookType = "PreToolUse"
var stdinJson: [String: Any]?

if let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
    stdinJson = json
    if let name = json["hook_event_name"] as? String {
        hookType = name
    }
}

// Override from env or argv if set (backwards compat with bash shims)
if let envType = ProcessInfo.processInfo.environment["CLAUDE_HOOK_TYPE"] {
    hookType = envType
} else if CommandLine.arguments.count > 1 {
    hookType = CommandLine.arguments[1]
}

let needsResponse = hookType == "PreToolUse" || hookType == "PermissionRequest"

// Build envelope
let timestamp = Date().timeIntervalSince1970
let pid = getppid()
let claudePid = findClaudePid(from: pid) ?? pid

var envelope: [String: Any] = [
    "hookType": hookType,
    "sessionPid": Int(claudePid),
    "timestamp": timestamp,
]

// Merge stdin JSON as payload (add "type" discriminator for daemon decoding)
if var payload = stdinJson {
    payload["type"] = hookType
    envelope["payload"] = payload
}

guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
    // Can't even build envelope — fail closed
    if needsResponse { printBlock("Gavel: failed to serialize hook envelope") }
    exit(needsResponse ? 2 : 0)
}

// Connect to daemon socket
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    // No socket — daemon not running. Fail OPEN so Claude works without gavel.
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
    // Can't connect — daemon not running. Fail OPEN so Claude works without gavel.
    if needsResponse { printAllow() }
    exit(0)
}

// Send envelope
envelopeData.withUnsafeBytes { ptr in
    _ = write(fd, ptr.baseAddress!, envelopeData.count)
}

// For PreToolUse/PermissionRequest, read response and translate to Claude's format
if needsResponse {
    shutdown(fd, SHUT_WR)

    var response = Data()
    let bufSize = 4096
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }

    var timeout = timeval(tv_sec: 300, tv_usec: 0) // 5 min — user may be reviewing
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    while true {
        let n = read(fd, buf, bufSize)
        if n <= 0 { break }
        response.append(buf, count: n)
    }
    close(fd)

    // Parse daemon response: {"verdict":"allow",...} or {"verdict":"block","reason":"..."}
    if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
       let verdict = json["verdict"] as? String {
        if verdict == "block" {
            let reason = (json["reason"] as? String) ?? "Blocked by Gavel"
            printBlock(reason)
            exit(2)
        }

        // Build structured allow response — format depends on hook type
        if hookType == "PermissionRequest" {
            printPermissionAllow()
            exit(0)
        }

        var output: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow"
        ]
        if let ctx = json["additionalContext"] as? String, !ctx.isEmpty {
            output["additionalContext"] = ctx
        }
        if let updated = json["updatedInput"] as? [String: Any] {
            output["updatedInput"] = updated
        }
        var wrapper: [String: Any] = ["hookSpecificOutput": output]
        if let ctx = json["additionalContext"] as? String, !ctx.isEmpty {
            wrapper["additionalContext"] = ctx
        }
        if let data = try? JSONSerialization.data(withJSONObject: wrapper),
           let str = String(data: data, encoding: .utf8) {
            print(str)
            exit(0)
        }
    }

    // Daemon was reachable but response was empty/unparseable — FAIL CLOSED
    printBlock("Gavel: daemon returned invalid response")
    exit(2)
} else {
    close(fd)
}

// MARK: - Helpers

func printAllow() {
    print(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#)
}

func printPermissionAllow() {
    print(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
}

func printBlock(_ reason: String) {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
}

// MARK: - Process tree walk (native, no subprocess)

func findClaudePid(from startPid: Int32) -> Int32? {
    var current = startPid
    for _ in 0..<8 {
        if let name = processName(pid: current),
           name.lowercased().contains("claude") {
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
