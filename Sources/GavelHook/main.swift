import Foundation
import GavelHookCore

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

// propose-rule is a flag-driven subcommand, not a hook shim — branch BEFORE the
// stdin read below, which would block forever on a terminal with no redirect.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "propose-rule" {
    runProposeRule()
}

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

// Build envelope. Codex stdin carries `turn_id` (Claude doesn't) — use that as
// the caller discriminator and walk the process tree for the right ancestor.
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

// Opt-in remote-approval request: the spawner sets GAVEL_REQUEST_PHONE on the
// launched session; the daemon only honors it on SessionStart.
let requestsRemoteApproval = ["1", "true", "yes"].contains(
    (ProcessInfo.processInfo.environment["GAVEL_REQUEST_PHONE"] ?? "").lowercased())

let spawnedSessionName = (ProcessInfo.processInfo.environment["GAVEL_SESSION_NAME"] ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

// Merge stdin JSON as payload (add "type" discriminator for daemon decoding)
if var payload = stdinJson {
    payload["type"] = hookType
    if hookType == "SessionStart", requestsRemoteApproval {
        payload["request_remote_approval"] = true
    }
    if hookType == "SessionStart", !spawnedSessionName.isEmpty {
        payload["session_name"] = spawnedSessionName
    }
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
    if needsResponse { printAllow(isCodex: isCodexAgent) }
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
    if needsResponse { printAllow(isCodex: isCodexAgent) }
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

    var timeout = timeval(tv_sec: 86400, tv_usec: 0) // 24 hours — effectively no timeout
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    while true {
        let n = read(fd, buf, bufSize)
        if n <= 0 { break }
        response.append(buf, count: n)
    }
    close(fd)

    // Parse daemon response: {"verdict":"allow",...} or {"verdict":"block","reason":"..."} or {} (passthrough)
    if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {

        // Empty {} = passthrough (daemon says "let Claude handle it")
        if json.isEmpty {
            print("{}")
            exit(0)
        }

        guard let verdict = json["verdict"] as? String else {
            // Has fields but no verdict — passthrough
            print("{}")
            exit(0)
        }
        if verdict == "block" {
            let reason = (json["reason"] as? String) ?? "Blocked by Gavel"
            printBlock(reason)
            exit(2)
        }

        // Build structured allow response — format depends on hook type
        if hookType == "PermissionRequest" {
            print(HookWireFormat.permissionRequestAllow())
            exit(0)
        }

        print(HookWireFormat.preToolUseAllow(
            isCodex: isCodexAgent,
            additionalContext: json["additionalContext"] as? String,
            updatedInput: json["updatedInput"] as? [String: Any]
        ))
        exit(0)
    }

    // Daemon was reachable but response was empty/unparseable — FAIL CLOSED
    printBlock("Gavel: daemon returned invalid response")
    exit(2)
} else {
    close(fd)
}

// MARK: - propose-rule subcommand

/// `gavel-hook propose-rule --tool <name> --pattern <p> --verdict <deny|prompt> --reason <why> [--example <cmd>] [--glob]`
///
/// Submits a tighten-only rule proposal to the daemon's pending inbox. The
/// daemon re-validates everything (verdict direction, regex compile, dedupe) —
/// this function is just transport + a readable result. Never returns.
func runProposeRule() -> Never {
    var tool: String?
    var pattern: String?
    var verdict: String?
    var reason: String?
    var example: String?
    var isRegex = true

    var args = CommandLine.arguments.dropFirst(2).makeIterator()
    while let flag = args.next() {
        switch flag {
        case "--tool": tool = args.next()
        case "--pattern": pattern = args.next()
        case "--verdict": verdict = args.next()
        case "--reason": reason = args.next()
        case "--example": example = args.next()
        case "--glob": isRegex = false
        default:
            FileHandle.standardError.write(Data("Unknown flag: \(flag)\n".utf8))
            exit(1)
        }
    }

    guard let tool, let pattern, let verdict, let reason else {
        let usage = """
        Usage: gavel-hook propose-rule --tool <name|*> --pattern <regex> --verdict <deny|prompt> \
        --reason <why this needs a gate> [--example <triggering command>] [--glob]

        Proposes a persistent Gavel rule for the user to review in the Monitor's Rules tab.
        Tighten-only: allow rules cannot be proposed. The proposal changes nothing until accepted.
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(1)
    }

    // Attribute the proposal to the agent session that spawned this call.
    let pid = getppid()
    let sessionPid = findAgentPid(from: pid, named: "claude")
        ?? findAgentPid(from: pid, named: "codex")
        ?? pid

    var payload: [String: Any] = [
        "type": "ProposeRule",
        "tool_name": tool,
        "pattern": pattern,
        "is_regex": isRegex,
        "verdict": verdict,
        "reason": reason,
    ]
    if let example { payload["example"] = example }

    let envelope: [String: Any] = [
        "hookType": "ProposeRule",
        "sessionPid": Int(sessionPid),
        "agent": "claude",
        "timestamp": Date().timeIntervalSince1970,
        "payload": payload,
    ]

    guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
        FileHandle.standardError.write(Data("propose-rule: failed to serialize proposal\n".utf8))
        exit(1)
    }

    guard let fd = daemonConnect() else {
        FileHandle.standardError.write(Data("propose-rule: Gavel daemon not running — proposal not submitted\n".utf8))
        exit(1)
    }

    envelopeData.withUnsafeBytes { ptr in
        _ = write(fd, ptr.baseAddress!, envelopeData.count)
    }
    shutdown(fd, SHUT_WR)

    var response = Data()
    let bufSize = 4096
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    while true {
        let n = read(fd, buf, bufSize)
        if n <= 0 { break }
        response.append(buf, count: n)
    }
    close(fd)

    guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        FileHandle.standardError.write(Data("propose-rule: no valid response from daemon\n".utf8))
        exit(1)
    }
    guard let status = json["status"] as? String else {
        // A verdict-shaped reply means an older daemon routed this through the
        // hook fallback — it predates rule proposals entirely.
        let hint = json["verdict"] != nil
            ? "running Gavel daemon predates rule proposals — update/restart Gavel and retry"
            : "no valid response from daemon"
        FileHandle.standardError.write(Data("propose-rule: \(hint)\n".utf8))
        exit(1)
    }

    if status == "queued" {
        let id = (json["id"] as? String) ?? "?"
        print("Proposal queued for user review in the Gavel Monitor (id \(id)). It has no effect until accepted.")
        exit(0)
    } else {
        let why = (json["reason"] as? String) ?? "unknown"
        print("Proposal rejected: \(why)")
        exit(1)
    }
}

/// Connect to the daemon socket. Returns nil when no daemon is listening.
func daemonConnect() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        return nil
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for (i, byte) in pathBytes.enumerated() {
                dest[i] = byte
            }
        }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

// MARK: - Helpers

func printAllow(isCodex: Bool) {
    print(HookWireFormat.preToolUseAllow(isCodex: isCodex))
}

func printBlock(_ reason: String) {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
}

// MARK: - Process tree walk (native, no subprocess)

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
