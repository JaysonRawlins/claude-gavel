import CryptoKit
import Foundation

/// Tier 2.5: a keyed signature over the last-known-good config, so a change made
/// while the daemon was NOT running (stop → tamper → start) is detected on load
/// instead of being silently adopted as truth.
///
/// The HMAC key lives in a separate 0600 file. This stops non-targeted tampering
/// (a script/installer/confused-deputy that rewrites the file without re-signing
/// it) — it does NOT stop an attacker who reads the key and forges the signature.
/// Only kernel enforcement (EndpointSecurity, Tier 3) crosses that line.
final class ConfigBaseline {
    private let keyPath: String

    init(keyPath: String) {
        self.keyPath = keyPath
    }

    func recordSignature(of data: Data, to path: String) {
        let hex = hexSignature(of: data)
        try? Data(hex.utf8).write(to: URL(fileURLWithPath: path))
    }

    func isValid(_ data: Data, against path: String) -> Bool {
        guard let stored = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return constantTimeEquals(stored, hexSignature(of: data))
    }

    func signatureExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func hexSignature(of data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: loadOrCreateKey())
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrCreateKey() -> SymmetricKey {
        if let existing = FileManager.default.contents(atPath: keyPath), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data(Array($0)) }
        let dir = (keyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyPath, contents: bytes, attributes: [.posixPermissions: 0o600])
        return key
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
