import XCTest
@testable import SessionNoticer

final class HookEventTests: XCTestCase {
    func testParseStopEvent() throws {
        let json = """
        {
            "event": "stop",
            "session_id": "abc-123",
            "pid": 12345,
            "cwd": "/Users/test/project",
            "transcript_path": "/Users/test/.claude/projects/abc-123.jsonl",
            "notification_type": "",
            "timestamp": 1774312900123
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.event, .stop)
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.pid, 12345)
        XCTAssertEqual(event.cwd, "/Users/test/project")
        XCTAssertNil(event.notificationType)
    }

    func testParseNotificationEvent() throws {
        let json = """
        {
            "event": "notification",
            "session_id": "abc-123",
            "pid": 12345,
            "cwd": "/Users/test/project",
            "transcript_path": "/Users/test/.claude/projects/abc-123.jsonl",
            "notification_type": "permission_prompt",
            "timestamp": 1774312900123
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.event, .notification)
        XCTAssertEqual(event.notificationType, .permissionPrompt)
    }

    func testMalformedJsonThrows() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(HookEvent.self, from: json))
    }
}
