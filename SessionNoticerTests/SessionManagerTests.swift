import XCTest
@testable import SessionNoticer

final class SessionManagerTests: XCTestCase {
    var manager: SessionManager!

    override func setUp() {
        manager = SessionManager()
    }

    func testSessionStartCreatesRunningSession() {
        let event = makeEvent(type: .sessionStart, sessionId: "s1")
        manager.processEvent(event)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions["s1"]?.state, .running)
    }

    func testStopTransitionsToIdle() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .idle)
    }

    func testNotificationPermissionTransitionsToNeedsPermission() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        XCTAssertEqual(manager.sessions["s1"]?.state, .needsPermission)
    }

    func testUserPromptTransitionsToRunning() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .userPrompt, sessionId: "s1"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .running)
    }

    func testSessionEndRemovesSession() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .sessionEnd, sessionId: "s1"))
        XCTAssertNil(manager.sessions["s1"])
    }

    func testNeedsPermissionCount() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s2"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        XCTAssertEqual(manager.needsAttentionCount, 1)
    }

    func testStopFromNeedsPermissionTransitionsToIdle() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .idle)
    }

    func testSessionEndFromAnyState() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .sessionEnd, sessionId: "s1"))
        XCTAssertNil(manager.sessions["s1"])
    }

    // MARK: - Helpers

    private func makeEvent(
        type: EventType,
        sessionId: String,
        notifType: NotificationType? = nil
    ) -> HookEvent {
        HookEvent(
            event: type,
            sessionId: sessionId,
            pid: 12345,
            cwd: "/Users/test/project",
            transcriptPath: "/Users/test/.claude/projects/test/\(sessionId).jsonl",
            notificationType: notifType,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
