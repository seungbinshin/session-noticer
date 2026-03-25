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

    func testStopTransitionsToAwaitingResponse() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .awaitingResponse)
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

    func testNeedsAttentionCountIncludesBothStates() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s2"))
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s3"))
        // s1: needs permission, s2: awaiting response, s3: running
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s2"))
        XCTAssertEqual(manager.needsAttentionCount, 2)
    }

    func testStopFromNeedsPermissionTransitionsToAwaitingResponse() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .awaitingResponse)
    }

    func testSessionEndFromAnyState() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .sessionEnd, sessionId: "s1"))
        XCTAssertNil(manager.sessions["s1"])
    }

    func testIdlePromptTransitionsToCompleted() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .idlePrompt))
        XCTAssertEqual(manager.sessions["s1"]?.state, .completed)
    }

    func testStopReturnsTrueWhenTransitioningFromRunning() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        let triggered = manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertTrue(triggered)
    }

    func testStopReturnsFalseWhenAlreadyAwaiting() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        let triggered = manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertFalse(triggered)
    }

    func testRemoteSessionCreatedWithHostname() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        XCTAssertEqual(manager.sessions["r1"]?.hostname, "ha-seattle")
        XCTAssertEqual(manager.sessions["r1"]?.source, .remote)
    }

    func testStaleRemoteSessionRemovedAfterTimeout() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        manager.sessions["r1"]?.lastUpdated = Date().addingTimeInterval(-130)
        manager.cleanupRemoteStaleSessions()
        XCTAssertNil(manager.sessions["r1"])
    }

    func testRecentRemoteSessionNotRemoved() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        manager.cleanupRemoteStaleSessions()
        XCTAssertNotNil(manager.sessions["r1"])
    }

    // MARK: - Helpers

    private func makeEvent(
        type: EventType,
        sessionId: String,
        notifType: NotificationType? = nil,
        hostname: String? = nil,
        source: String? = nil
    ) -> HookEvent {
        HookEvent(
            event: type,
            sessionId: sessionId,
            pid: 12345,
            cwd: "/Users/test/project",
            transcriptPath: "/Users/test/.claude/projects/test/\(sessionId).jsonl",
            notificationType: notifType,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hostname: hostname,
            source: source
        )
    }
}
