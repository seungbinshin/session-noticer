import XCTest
@testable import SessionNoticer

final class EventWatcherTests: XCTestCase {
    var tempDir: URL!
    var watcher: EventWatcher!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("event-watcher-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        watcher = EventWatcher(eventsDirectory: tempDir)
    }

    override func tearDown() {
        watcher.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDispatchSourceFiresWithinOneSecond() throws {
        let expectation = expectation(description: "onEvent fired")
        watcher.onEvent = { event in
            XCTAssertEqual(event.sessionId, "watcher-test")
            expectation.fulfill()
        }
        watcher.start()

        // Atomic write (mimics the hook script) so the watcher sees a complete file.
        let payload: [String: Any] = [
            "event": "session_start",
            "session_id": "watcher-test",
            "pid": 1,
            "cwd": "/tmp/x",
            "transcript_path": "",
            "timestamp": 0,
        ]
        let tmp = tempDir.appendingPathComponent("pending.tmp")
        let final = tempDir.appendingPathComponent("1-session_start.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: final)

        // 1s is ample for a kqueue event; the fallback poll is 5s so a pass here
        // proves the DispatchSource path works.
        wait(for: [expectation], timeout: 1.0)
    }
}
