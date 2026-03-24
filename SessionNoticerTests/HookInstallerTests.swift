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

    func testInstallsHooksIntoEmptySettings() throws {
        let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
        try installer.installHooks()

        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["SessionEnd"])
    }

    func testPreservesExistingSettings() throws {
        let existing = """
        {"allowedTools": ["bash"], "hooks": {"PreCompact": [{"type": "command", "command": "echo compacting"}]}}
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
}
