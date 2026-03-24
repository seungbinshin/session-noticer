import XCTest
@testable import SessionNoticer

final class SessionScannerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-scanner-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDiscoverSessionFromPidFile() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidFile = tempDir.appendingPathComponent("\(pid).json")
        let pidData: [String: Any] = ["pid": pid, "sessionId": "test-session-id", "cwd": "/Users/test/myproject", "startedAt": 1774312900000]
        try JSONSerialization.data(withJSONObject: pidData).write(to: pidFile)

        let scanner = SessionScanner(sessionsDirectory: tempDir)
        let sessions = scanner.discoverSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "test-session-id")
        XCTAssertEqual(sessions.first?.projectName, "myproject")
        XCTAssertEqual(sessions.first?.state, .running)
    }

    func testSkipsDeadPid() throws {
        let pidFile = tempDir.appendingPathComponent("999999.json")
        let pidData: [String: Any] = ["pid": 999999, "sessionId": "dead-session", "cwd": "/Users/test/project", "startedAt": 1774312900000]
        try JSONSerialization.data(withJSONObject: pidData).write(to: pidFile)

        let scanner = SessionScanner(sessionsDirectory: tempDir)
        let sessions = scanner.discoverSessions()
        XCTAssertEqual(sessions.count, 0)
    }
}
