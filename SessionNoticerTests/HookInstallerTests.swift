import XCTest
@testable import SessionNoticer

final class HookInstallerTests: XCTestCase {
    var tempDir: URL!
    var settingsPath: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-installer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsPath = tempDir.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstallsHooksWithCorrectFormat() throws {
        let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
        try installer.installHooks()

        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        // Verify all 5 events are registered
        for event in ["SessionStart", "Stop", "Notification", "UserPromptSubmit", "SessionEnd"] {
            let matchers = hooks[event] as! [[String: Any]]
            XCTAssertEqual(matchers.count, 1, "Expected 1 matcher for \(event)")

            // Verify matcher + hooks array format
            let matcher = matchers[0]
            XCTAssertEqual(matcher["matcher"] as? String, "", "Matcher should be empty string for \(event)")
            let hooksList = matcher["hooks"] as! [[String: Any]]
            XCTAssertEqual(hooksList.count, 1)
            XCTAssertEqual(hooksList[0]["type"] as? String, "command")
            XCTAssert((hooksList[0]["command"] as? String)?.contains("session-noticer-hook") == true)
        }
    }

    func testPreservesExistingSettings() throws {
        let existing = """
        {"allowedTools": ["bash"], "hooks": {"PreCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "echo compacting"}]}]}}
        """.data(using: .utf8)!
        try existing.write(to: settingsPath)

        let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
        try installer.installHooks()

        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["allowedTools"])
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["SessionStart"])
    }

    func testDoesNotDuplicateHooks() throws {
        let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
        try installer.installHooks()
        try installer.installHooks() // second call

        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let matchers = hooks["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(matchers.count, 1, "Should not duplicate hook entries")
    }
}
