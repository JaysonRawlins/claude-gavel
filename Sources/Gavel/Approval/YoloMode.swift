import CryptoKit
import Foundation

/// Plan-gated YOLO mode: bypass user-authored rules between engage and halt.
///
/// While engaged, the approval engine takes an early branch that honors only
/// stage-1 hard-block patterns, sensitive-path protection (which halts YOLO),
/// and built-in scheduler prompts. User DENY / PROMPT / ALLOW / session rules
/// are skipped. Halt triggers:
///   1. Agent issues Write/Edit/MultiEdit on the tracked plan path.
///   2. Plan file's sha256 differs from the hash captured at engage time.
///   3. Plan file is deleted.
///   4. Tool call hits matchSensitivePath (gavel-protected surface).
///   5. Manual disengage via the UI.
///
/// Discovery is via `session.lastPlanPath`, stamped by HookRouter when an
/// approved Write/Edit/MultiEdit lands on ~/.claude/plans/**/*.md. This
/// avoids coupling to session-label/folder conventions.
enum YoloMode {
    private static let planPathRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #".*/\.claude/plans/[^/]+/[^/]+\.md$"#)
    }()

    static func canEngage(session: Session) -> (Bool, reason: String?) {
        guard let path = session.lastPlanPath else {
            return (false, "No plan captured yet — run /propose first")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "Plan file no longer exists: \((path as NSString).lastPathComponent)")
        }
        return (true, nil)
    }

    @discardableResult
    static func engage(session: Session) -> Bool {
        let (ok, _) = canEngage(session: session)
        guard ok, let path = session.lastPlanPath else { return false }
        let hash = sha256(ofFileAt: path)
        let overlay = (try? String(contentsOfFile: path, encoding: .utf8)).map(PlanPolicyParser.parse) ?? []
        session.overlayRules = overlay
        session.setYoloActive(true)
        DispatchQueue.main.async {
            session.yoloEngagedAt = Date()
            session.yoloPlanPath = path
            session.yoloPlanHash = hash
            session.yoloDisabledReason = nil
            session.isSubAgentInheritEnabled = true
            session.isAutoApproveEnabled = true
        }
        return true
    }

    /// Returns disengage reason or nil. Read-only — safe from any thread.
    static func shouldHalt(session: Session, payload: PreToolUsePayload) -> String? {
        guard let trackedPath = session.yoloPlanPath else { return nil }

        if ["Write", "Edit", "MultiEdit"].contains(payload.toolName),
           let path = payload.filePath,
           pathsEqual(path, trackedPath) {
            return "plan modified by agent"
        }

        guard let currentHash = sha256(ofFileAt: trackedPath) else {
            return "plan deleted"
        }
        if currentHash != session.yoloPlanHash {
            return "plan changed on disk"
        }
        return nil
    }

    /// Clears YOLO state and records the reason. Posts a notification.
    /// Caller is responsible for calling `SessionManager.saveActiveSessions()` after.
    static func disengage(session: Session, reason: String) {
        session.setYoloActive(false)
        session.overlayRules = []
        DispatchQueue.main.async {
            session.yoloEngagedAt = nil
            session.yoloPlanPath = nil
            session.yoloPlanHash = nil
            session.yoloDisabledReason = reason
            session.isAutoApproveEnabled = false
        }
        GavelNotifications.notify(title: "Gavel — plan policy dropped", body: reason)
    }

    static func isPlanPath(_ path: String) -> Bool {
        let nsPath = path as NSString
        let range = NSRange(location: 0, length: nsPath.length)
        return planPathRegex.firstMatch(in: path, range: range) != nil
    }

    /// A discoverable plan file under `~/.claude/plans/<folder>/<file>.md`.
    struct PlanRef: Identifiable {
        let path: String
        let folder: String
        let filename: String
        let modifiedAt: Date
        var id: String { path }
    }

    static func plansDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/plans", isDirectory: true)
    }

    /// One level deep, `.md` only, newest-modified first. Mirrors the
    /// `plans/<folder>/<file>.md` shape `isPlanPath` enforces, so the manual
    /// picker offers exactly the files capture-on-write would have stamped.
    static func recentPlans(in baseDir: URL = plansDirectory(), limit: Int = 15) -> [PlanRef] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var refs: [PlanRef] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "md" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                refs.append(PlanRef(
                    path: file.path,
                    folder: folder.lastPathComponent,
                    filename: file.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return Array(refs.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }

    static func sha256(ofFileAt path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pathsEqual(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }
}
