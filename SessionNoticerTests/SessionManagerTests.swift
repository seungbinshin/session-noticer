import XCTest
@testable import SessionNoticer

final class SessionManagerTests: XCTestCase {
    var manager: SessionManager!

    override func setUp() {
        // Tests use synthetic PIDs; bypass the TTY filter.
        manager = SessionManager(ttyCheck: { _ in true })
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

    func testNeedsAttentionCountOnlyPermission() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s2"))
        // s1: needs permission, s2: awaiting response (done, not urgent)
        manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
        manager.processEvent(makeEvent(type: .stop, sessionId: "s2"))
        XCTAssertEqual(manager.needsAttentionCount, 1) // only permission counts
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

    func testStopNeverTriggersBanner() {
        manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
        let triggered = manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
        XCTAssertFalse(triggered) // Stop = Done, not urgent, no banner
    }

    func testRemoteSessionCreatedWithHostname() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        XCTAssertEqual(manager.sessions["r1"]?.hostname, "ha-seattle")
        XCTAssertEqual(manager.sessions["r1"]?.source, .remote)
    }

    func testStaleCompletedRemoteSessionBecomesIdleAfterTimeout() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        // Transition to completed (idle_prompt), then age it past 30min
        manager.processEvent(makeEvent(type: .notification, sessionId: "r1", notifType: .idlePrompt, hostname: "ha-seattle", source: "remote"))
        manager.sessions["r1"]?.lastUpdated = Date().addingTimeInterval(-1810)
        manager.cleanupRemoteStaleSessions()
        XCTAssertNotNil(manager.sessions["r1"])
        XCTAssertEqual(manager.sessions["r1"]?.state, .idle)
    }

    func testCompletedRemoteSessionSurvivesShortTimeout() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        // Completed session aged 5 minutes — should NOT become idle (needs 30min)
        manager.processEvent(makeEvent(type: .notification, sessionId: "r1", notifType: .idlePrompt, hostname: "ha-seattle", source: "remote"))
        manager.sessions["r1"]?.lastUpdated = Date().addingTimeInterval(-300)
        manager.cleanupRemoteStaleSessions()
        XCTAssertEqual(manager.sessions["r1"]?.state, .completed)
    }

    func testRunningRemoteSessionSurvivesShortTimeout() {
        let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
        manager.processEvent(event)
        // Running session aged 5 minutes — should NOT be removed (needs 30min)
        manager.sessions["r1"]?.lastUpdated = Date().addingTimeInterval(-300)
        manager.cleanupRemoteStaleSessions()
        XCTAssertNotNil(manager.sessions["r1"])
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
