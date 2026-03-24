# Session Noticer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app that monitors Claude Code CLI sessions and notifies the user when a session needs attention (permission prompt), with click-to-focus on the iTerm2 tab.

**Architecture:** Hooks-based event detection via file IPC. Claude Code hooks write JSON event files to an events directory; the Swift app watches with FSEvents, maintains an in-memory session state machine, and renders a SwiftUI menu bar popover. A slide-down banner NSWindow alerts the user when a session needs permission.

**Tech Stack:** Swift 5+, SwiftUI, AppKit (NSStatusItem, NSWindow for banner), FSEvents via DispatchSource, AppleScript for iTerm2 focusing.

**Spec:** `docs/superpowers/specs/2026-03-24-session-noticer-design.md`

---

## File Structure

```
SessionNoticer/
├── SessionNoticer.xcodeproj/
├── SessionNoticer/
│   ├── SessionNoticerApp.swift          # App entry point, menu bar setup
│   ├── Models/
│   │   ├── Session.swift                # Session struct + SessionState enum
│   │   └── HookEvent.swift              # Event JSON Codable model
│   ├── Services/
│   │   ├── SessionManager.swift         # Owns session list, state machine, @Published
│   │   ├── EventWatcher.swift           # FSEvents directory watcher
│   │   ├── SessionScanner.swift         # Reads ~/.claude/sessions/ on launch
│   │   ├── HookInstaller.swift          # First-launch hook setup
│   │   └── ITerm2Focuser.swift          # AppleScript iTerm2 tab focusing
│   ├── Views/
│   │   ├── MenuBarView.swift            # Dropdown popover content
│   │   ├── SessionRowView.swift         # Single session row in dropdown
│   │   └── SettingsView.swift           # Settings window (minimal)
│   ├── Banner/
│   │   └── BannerController.swift       # Slide-down banner NSWindow
│   ├── Resources/
│   │   ├── Assets.xcassets/             # Claude robot icon (green + orange variants)
│   │   └── session-noticer-hook         # Shell script bundled in app
│   └── Info.plist
├── SessionNoticerTests/
│   ├── SessionManagerTests.swift        # State machine transition tests
│   ├── HookEventTests.swift             # JSON parsing tests
│   ├── SessionScannerTests.swift        # Session discovery tests
│   └── HookInstallerTests.swift         # Settings.json merge tests
└── README.md
```

---

### Task 1: Create Xcode Project Skeleton

**Files:**
- Create: `SessionNoticer.xcodeproj` (via xcodebuild)
- Create: `SessionNoticer/SessionNoticerApp.swift`
- Create: `SessionNoticer/Info.plist`

- [ ] **Step 1: Create the Xcode project**

Use `swift package init` or create manually. The app is a macOS menu bar-only app (no dock icon, no main window).

```bash
cd /Users/shinseungbin/workspace/session_noticer
mkdir -p SessionNoticer/SessionNoticer
```

- [ ] **Step 2: Create the app entry point**

Create `SessionNoticer/SessionNoticer/SessionNoticerApp.swift`:

```swift
import SwiftUI

@main
struct SessionNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
        }
    }
}
```

- [ ] **Step 3: Create Package.swift for SPM-based build**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionNoticer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SessionNoticer",
            path: "SessionNoticer"
        ),
        .testTarget(
            name: "SessionNoticerTests",
            dependencies: ["SessionNoticer"],
            path: "SessionNoticerTests"
        ),
    ]
)
```

- [ ] **Step 4: Build and verify the app launches with a menu bar icon**

```bash
cd /Users/shinseungbin/workspace/session_noticer
swift build
```

Expected: Builds successfully. Running the binary shows a small icon in the menu bar.

- [ ] **Step 5: Commit**

```bash
git init
echo ".build/\n.superpowers/\n.DS_Store" > .gitignore
git add Package.swift SessionNoticer/ .gitignore
git commit -m "feat: create project skeleton with menu bar status item"
```

---

### Task 2: Data Models (Session + HookEvent)

**Files:**
- Create: `SessionNoticer/Models/Session.swift`
- Create: `SessionNoticer/Models/HookEvent.swift`
- Test: `SessionNoticerTests/HookEventTests.swift`

- [ ] **Step 1: Write failing test for HookEvent JSON parsing**

Create `SessionNoticerTests/HookEventTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter HookEventTests
```

Expected: FAIL — `HookEvent` not defined.

- [ ] **Step 3: Implement the models**

Create `SessionNoticer/Models/HookEvent.swift`:

```swift
import Foundation

enum EventType: String, Codable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case stop
    case notification
    case userPrompt = "user_prompt"
}

enum NotificationType: String, Codable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
}

struct HookEvent: Codable {
    let event: EventType
    let sessionId: String
    let pid: Int
    let cwd: String
    let transcriptPath: String
    let notificationType: NotificationType?
    let timestamp: Int64

    enum CodingKeys: String, CodingKey {
        case event
        case sessionId = "session_id"
        case pid
        case cwd
        case transcriptPath = "transcript_path"
        case notificationType = "notification_type"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(EventType.self, forKey: .event)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        pid = try container.decode(Int.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)
        transcriptPath = try container.decode(String.self, forKey: .transcriptPath)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)

        // notification_type may be empty string — treat as nil
        let rawNotifType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        if let raw = rawNotifType, !raw.isEmpty {
            notificationType = NotificationType(rawValue: raw)
        } else {
            notificationType = nil
        }
    }
}
```

Create `SessionNoticer/Models/Session.swift`:

```swift
import Foundation

enum SessionState {
    case running
    case idle
    case needsPermission
}

struct Session: Identifiable {
    let id: String  // session_id (UUID)
    let pid: Int
    let cwd: String
    let transcriptPath: String
    var projectName: String
    var firstPrompt: String
    var state: SessionState
    var lastUpdated: Date
    var tty: String?

    init(sessionId: String, pid: Int, cwd: String, transcriptPath: String) {
        self.id = sessionId
        self.pid = pid
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.firstPrompt = ""
        self.state = .running
        self.lastUpdated = Date()
        self.tty = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter HookEventTests
```

Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Models/ SessionNoticerTests/HookEventTests.swift
git commit -m "feat: add Session and HookEvent data models with JSON parsing"
```

---

### Task 3: SessionManager (State Machine)

**Files:**
- Create: `SessionNoticer/Services/SessionManager.swift`
- Test: `SessionNoticerTests/SessionManagerTests.swift`

- [ ] **Step 1: Write failing tests for state transitions**

Create `SessionNoticerTests/SessionManagerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionManagerTests
```

Expected: FAIL — `SessionManager` not defined.

- [ ] **Step 3: Implement SessionManager**

Create `SessionNoticer/Services/SessionManager.swift`:

```swift
import Foundation
import Combine

class SessionManager: ObservableObject {
    @Published var sessions: [String: Session] = [:]

    var needsAttentionCount: Int {
        sessions.values.filter { $0.state == .needsPermission }.count
    }

    var sortedSessions: [Session] {
        sessions.values.sorted { a, b in
            // Needs permission first, then running, then idle
            let order: (SessionState) -> Int = {
                switch $0 {
                case .needsPermission: return 0
                case .running: return 1
                case .idle: return 2
                }
            }
            if order(a.state) != order(b.state) {
                return order(a.state) < order(b.state)
            }
            return a.lastUpdated > b.lastUpdated
        }
    }

    /// Returns true if the event triggered a transition to needsPermission (for banner)
    @discardableResult
    func processEvent(_ event: HookEvent) -> Bool {
        switch event.event {
        case .sessionStart:
            if sessions[event.sessionId] == nil {
                var session = Session(
                    sessionId: event.sessionId,
                    pid: event.pid,
                    cwd: event.cwd,
                    transcriptPath: event.transcriptPath
                )
                session.state = .running
                session.lastUpdated = Date()
                sessions[event.sessionId] = session
            }
            return false

        case .sessionEnd:
            sessions.removeValue(forKey: event.sessionId)
            return false

        case .stop:
            guard sessions[event.sessionId] != nil else { return false }
            sessions[event.sessionId]?.state = .idle
            sessions[event.sessionId]?.lastUpdated = Date()
            return false

        case .notification:
            guard sessions[event.sessionId] != nil else { return false }
            if event.notificationType == .permissionPrompt {
                let wasNotAlready = sessions[event.sessionId]?.state != .needsPermission
                sessions[event.sessionId]?.state = .needsPermission
                sessions[event.sessionId]?.lastUpdated = Date()
                return wasNotAlready
            } else if event.notificationType == .idlePrompt {
                sessions[event.sessionId]?.state = .idle
                sessions[event.sessionId]?.lastUpdated = Date()
            }
            return false

        case .userPrompt:
            guard sessions[event.sessionId] != nil else { return false }
            sessions[event.sessionId]?.state = .running
            sessions[event.sessionId]?.lastUpdated = Date()
            return false
        }
    }

    func addDiscoveredSession(_ session: Session) {
        sessions[session.id] = session
    }
}
```

Also add a memberwise initializer to `HookEvent` for test use. Append to `HookEvent.swift`:

```swift
extension HookEvent {
    init(event: EventType, sessionId: String, pid: Int, cwd: String,
         transcriptPath: String, notificationType: NotificationType?, timestamp: Int64) {
        self.event = event
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.timestamp = timestamp
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SessionManagerTests
```

Expected: All 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Services/SessionManager.swift SessionNoticerTests/SessionManagerTests.swift
git commit -m "feat: add SessionManager with complete state machine transitions"
```

---

### Task 4: EventWatcher (FSEvents Directory Watcher)

**Files:**
- Create: `SessionNoticer/Services/EventWatcher.swift`

- [ ] **Step 1: Implement EventWatcher**

Create `SessionNoticer/Services/EventWatcher.swift`:

```swift
import Foundation

class EventWatcher {
    private let eventsDirectory: URL
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    var onEvent: ((HookEvent) -> Void)?

    init(eventsDirectory: URL) {
        self.eventsDirectory = eventsDirectory

        // Create events directory if needed
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        self.fileDescriptor = open(eventsDirectory.path, O_EVTONLY)
    }

    deinit {
        stop()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    func processExistingEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } // timestamp-based names sort chronologically

        for file in jsonFiles {
            processEventFile(file)
        }
    }

    func start() {
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.checkForNewEvents()
        }

        source.setCancelHandler { }
        source.resume()
        self.dispatchSource = source
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    private func checkForNewEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in jsonFiles {
            processEventFile(file)
        }
    }

    private func processEventFile(_ file: URL) {
        defer {
            try? FileManager.default.removeItem(at: file)
        }

        guard let data = try? Data(contentsOf: file) else { return }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            NSLog("SessionNoticer: Failed to parse event file: \(file.lastPathComponent)")
            return
        }

        onEvent?(event)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/Services/EventWatcher.swift
git commit -m "feat: add EventWatcher with FSEvents directory monitoring"
```

---

### Task 5: SessionScanner (Launch-time Session Discovery)

**Files:**
- Create: `SessionNoticer/Services/SessionScanner.swift`
- Test: `SessionNoticerTests/SessionScannerTests.swift`

- [ ] **Step 1: Write failing test**

Create `SessionNoticerTests/SessionScannerTests.swift`:

```swift
import XCTest
@testable import SessionNoticer

final class SessionScannerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scanner-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDiscoverSessionFromPidFile() throws {
        // Create a fake PID file using current process PID (so it's "alive")
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidFile = tempDir.appendingPathComponent("\(pid).json")
        let pidData: [String: Any] = [
            "pid": pid,
            "sessionId": "test-session-id",
            "cwd": "/Users/test/myproject",
            "startedAt": 1774312900000
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: pidData)
        try jsonData.write(to: pidFile)

        let scanner = SessionScanner(sessionsDirectory: tempDir)
        let sessions = scanner.discoverSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "test-session-id")
        XCTAssertEqual(sessions.first?.projectName, "myproject")
        XCTAssertEqual(sessions.first?.state, .running)
    }

    func testSkipsDeadPid() throws {
        // Use PID 999999 which is almost certainly not running
        let pidFile = tempDir.appendingPathComponent("999999.json")
        let pidData: [String: Any] = [
            "pid": 999999,
            "sessionId": "dead-session",
            "cwd": "/Users/test/project",
            "startedAt": 1774312900000
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: pidData)
        try jsonData.write(to: pidFile)

        let scanner = SessionScanner(sessionsDirectory: tempDir)
        let sessions = scanner.discoverSessions()

        XCTAssertEqual(sessions.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionScannerTests
```

Expected: FAIL — `SessionScanner` not defined.

- [ ] **Step 3: Implement SessionScanner**

Create `SessionNoticer/Services/SessionScanner.swift`:

```swift
import Foundation

struct SessionPidFile: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Int64
}

class SessionScanner {
    private let sessionsDirectory: URL

    init(sessionsDirectory: URL? = nil) {
        self.sessionsDirectory = sessionsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions")
    }

    func discoverSessions() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { parseAndValidate($0) }
    }

    private func parseAndValidate(_ file: URL) -> Session? {
        guard let data = try? Data(contentsOf: file),
              let pidFile = try? JSONDecoder().decode(SessionPidFile.self, from: data)
        else { return nil }

        // Check if PID is alive
        guard kill(Int32(pidFile.pid), 0) == 0 else { return nil }

        var session = Session(
            sessionId: pidFile.sessionId,
            pid: pidFile.pid,
            cwd: pidFile.cwd,
            transcriptPath: "" // Will be populated if available
        )
        session.state = .running
        session.firstPrompt = extractFirstPrompt(sessionId: pidFile.sessionId, cwd: pidFile.cwd)
        return session
    }

    private func extractFirstPrompt(sessionId: String, cwd: String) -> String {
        // Build the project path encoding: slashes replaced with dashes
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return ""
        }

        // Find JSONL transcript for this session
        for dir in projectDirs {
            let transcriptPath = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                return readFirstUserPrompt(from: transcriptPath)
            }
        }
        return ""
    }

    private func readFirstUserPrompt(from path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { handle.closeFile() }

        // Read first ~8KB to find the first user message
        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return "" }

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Look for user message type
            if let msgType = (json["data"] as? [String: Any])?["type"] as? String,
               msgType == "human" || msgType == "user" {
                if let content = extractTextContent(from: json) {
                    let truncated = String(content.prefix(60))
                    return content.count > 60 ? truncated + "..." : truncated
                }
            }

            // Alternative format: message.message.role
            if let msg = (json["data"] as? [String: Any])?["message"] as? [String: Any],
               let innerMsg = msg["message"] as? [String: Any],
               let role = innerMsg["role"] as? String,
               role == "user" {
                if let content = innerMsg["content"] as? String {
                    let truncated = String(content.prefix(60))
                    return content.count > 60 ? truncated + "..." : truncated
                }
                if let contentArray = innerMsg["content"] as? [[String: Any]],
                   let firstText = contentArray.first(where: { $0["type"] as? String == "text" }),
                   let text = firstText["text"] as? String {
                    let truncated = String(text.prefix(60))
                    return text.count > 60 ? truncated + "..." : truncated
                }
            }
        }
        return ""
    }

    private func extractTextContent(from json: [String: Any]) -> String? {
        if let data = json["data"] as? [String: Any],
           let message = data["message"] as? [String: Any] {
            if let text = message["text"] as? String { return text }
            if let content = message["content"] as? String { return content }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SessionScannerTests
```

Expected: All 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Services/SessionScanner.swift SessionNoticerTests/SessionScannerTests.swift
git commit -m "feat: add SessionScanner for launch-time session discovery"
```

---

### Task 6: HookInstaller (First-Launch Setup)

**Files:**
- Create: `SessionNoticer/Services/HookInstaller.swift`
- Test: `SessionNoticerTests/HookInstallerTests.swift`

- [ ] **Step 1: Write failing test for merging hooks into settings**

Create `SessionNoticerTests/HookInstallerTests.swift`:

```swift
import XCTest
@testable import SessionNoticer

final class HookInstallerTests: XCTestCase {
    var tempDir: URL!
    var settingsPath: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-installer-test-\(UUID().uuidString)")
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
        {
            "allowedTools": ["bash"],
            "hooks": {
                "PreCompact": [{"type": "command", "command": "echo compacting"}]
            }
        }
        """.data(using: .utf8)!
        try existing.write(to: settingsPath)

        let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
        try installer.installHooks()

        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Existing settings preserved
        XCTAssertNotNil(json["allowedTools"])

        // Existing hooks preserved
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["PreCompact"])

        // New hooks added
        XCTAssertNotNil(hooks["SessionStart"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter HookInstallerTests
```

Expected: FAIL — `HookInstaller` not defined.

- [ ] **Step 3: Implement HookInstaller**

Create `SessionNoticer/Services/HookInstaller.swift`:

```swift
import Foundation

class HookInstaller {
    private let settingsPath: URL
    private let hookScriptPath: String

    init(settingsPath: URL? = nil, hookScriptPath: String? = nil) {
        self.settingsPath = settingsPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
        self.hookScriptPath = hookScriptPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/session-noticer-hook").path
    }

    func installHooks() throws {
        var settings = loadExistingSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookEvents = [
            ("SessionStart", "session_start"),
            ("SessionEnd", "session_end"),
            ("Stop", "stop"),
            ("Notification", "notification"),
            ("UserPromptSubmit", "user_prompt"),
        ]

        for (eventName, argName) in hookEvents {
            var eventHooks = hooks[eventName] as? [[String: Any]] ?? []
            let command = "\(hookScriptPath) \(argName)"

            // Don't add duplicate
            let alreadyExists = eventHooks.contains { ($0["command"] as? String) == command }
            if !alreadyExists {
                eventHooks.append([
                    "type": "command",
                    "command": command,
                ])
            }
            hooks[eventName] = eventHooks
        }

        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsPath)
    }

    func installHookScript(from bundlePath: String) throws {
        let targetURL = URL(fileURLWithPath: hookScriptPath)
        let targetDir = targetURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Remove existing symlink if present
        if FileManager.default.fileExists(atPath: hookScriptPath) {
            try FileManager.default.removeItem(atPath: hookScriptPath)
        }

        try FileManager.default.createSymbolicLink(atPath: hookScriptPath, withDestinationPath: bundlePath)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundlePath
        )
    }

    private func loadExistingSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter HookInstallerTests
```

Expected: All 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Services/HookInstaller.swift SessionNoticerTests/HookInstallerTests.swift
git commit -m "feat: add HookInstaller for first-launch hook setup"
```

---

### Task 7: session-noticer-hook Shell Script

**Files:**
- Create: `SessionNoticer/Resources/session-noticer-hook`

- [ ] **Step 1: Create the hook shell script**

Create `SessionNoticer/Resources/session-noticer-hook`:

```bash
#!/bin/bash
# session-noticer-hook: Called by Claude Code hooks to write event files
# Usage: session-noticer-hook <event_type>
# Reads hook JSON payload from stdin

set -euo pipefail

EVENT_TYPE="${1:-unknown}"
EVENTS_DIR="$HOME/Library/Application Support/SessionNoticer/events"
mkdir -p "$EVENTS_DIR"

# Read full payload from stdin
PAYLOAD=$(cat)

# Extract all fields and write event file in a single python3 call
# This avoids shell word-splitting issues with paths containing spaces
printf '%s' "$PAYLOAD" | /usr/bin/python3 -c "
import sys, json, time, os

d = json.load(sys.stdin)
ts = int(time.time() * 1000)
event_type = '${EVENT_TYPE}'
ppid = ${PPID}

event = {
    'event': event_type,
    'session_id': d.get('session_id', 'unknown'),
    'pid': ppid,
    'cwd': d.get('cwd', ''),
    'transcript_path': d.get('transcript_path', ''),
    'notification_type': d.get('notification_type', ''),
    'timestamp': ts
}

# Use timestamp-eventtype-pid.json to avoid collisions
filename = f'{ts}-{event_type}-{ppid}.json'
events_dir = os.path.expanduser('~/Library/Application Support/SessionNoticer/events')
filepath = os.path.join(events_dir, filename)

# If file exists (extremely unlikely), append random suffix
if os.path.exists(filepath):
    import random, string
    suffix = ''.join(random.choices(string.ascii_lowercase, k=4))
    filename = f'{ts}-{event_type}-{ppid}-{suffix}.json'
    filepath = os.path.join(events_dir, filename)

with open(filepath, 'w') as f:
    json.dump(event, f)
"
```

- [ ] **Step 2: Make it executable and test manually**

```bash
chmod +x SessionNoticer/Resources/session-noticer-hook
echo '{"session_id":"test-123","cwd":"/tmp/test","transcript_path":"/tmp/test.jsonl","notification_type":""}' | ./SessionNoticer/Resources/session-noticer-hook stop
ls ~/Library/Application\ Support/SessionNoticer/events/
cat ~/Library/Application\ Support/SessionNoticer/events/*.json
```

Expected: A JSON file appears in the events directory with the correct fields.

- [ ] **Step 3: Clean up test event and commit**

```bash
rm -f ~/Library/Application\ Support/SessionNoticer/events/*.json
git add SessionNoticer/Resources/session-noticer-hook
git commit -m "feat: add session-noticer-hook shell script for Claude Code hooks"
```

---

### Task 8: Menu Bar UI (Icon + Dropdown Popover)

> **Note:** The AppDelegate in Step 3 references `BannerController` (Task 9) and `ITerm2Focuser` (Task 10). When implementing, either create stub files first or implement Tasks 8-10 together. The code will compile fully after Task 10 is complete.

**Files:**
- Modify: `SessionNoticer/SessionNoticerApp.swift`
- Create: `SessionNoticer/Views/MenuBarView.swift`
- Create: `SessionNoticer/Views/SessionRowView.swift`

- [ ] **Step 1: Create SessionRowView**

Create `SessionNoticer/Views/SessionRowView.swift`:

```swift
import SwiftUI

struct SessionRowView: View {
    let session: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Orange left border for needs-permission
                if session.state == .needsPermission {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange)
                        .frame(width: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    if !session.firstPrompt.isEmpty {
                        Text(session.firstPrompt)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                StatusPill(state: session.state)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(session.state == .needsPermission ? Color.orange.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusPill: View {
    let state: SessionState

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .running: return "Running"
        case .idle: return "Idle"
        case .needsPermission: return "Needs Permission"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .running: return .green
        case .idle: return .gray
        case .needsPermission: return .orange
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .running: return .green.opacity(0.15)
        case .idle: return .gray.opacity(0.15)
        case .needsPermission: return .orange.opacity(0.15)
        }
    }
}
```

- [ ] **Step 2: Create MenuBarView**

Create `SessionNoticer/Views/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var sessionManager: SessionManager
    var onSessionTap: (Session) -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if sessionManager.sortedSessions.isEmpty {
                VStack(spacing: 8) {
                    Text("No active sessions")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Start a Claude Code session to see it here")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                ForEach(sessionManager.sortedSessions) { session in
                    SessionRowView(session: session) {
                        onSessionTap(session)
                    }

                    if session.id != sessionManager.sortedSessions.last?.id {
                        Divider().padding(.horizontal, 8)
                    }
                }
            }

            Divider()

            HStack {
                Button("Quit") { onQuit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}
```

- [ ] **Step 3: Update AppDelegate to wire up the popover**

Replace `SessionNoticer/SessionNoticerApp.swift` with:

```swift
import SwiftUI

@main
struct SessionNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let sessionManager = SessionManager()
    private var eventWatcher: EventWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupEventWatcher()
        scanExistingSessions()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateIcon()
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.delegate = self
        let view = MenuBarView(
            sessionManager: sessionManager,
            onSessionTap: { [weak self] session in
                guard let self else { return }
                self.popover.performClose(nil)
                ITerm2Focuser.focusSession(session, in: self.sessionManager)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    private func setupEventWatcher() {
        let eventsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SessionNoticer/events")

        BannerController.shared.sessionManager = sessionManager

        eventWatcher = EventWatcher(eventsDirectory: eventsDir)
        eventWatcher?.onEvent = { [weak self] event in
            guard let self else { return }
            let triggered = self.sessionManager.processEvent(event)
            self.updateIcon()
            if triggered {
                BannerController.shared.showBanner(for: self.sessionManager.sessions[event.sessionId])
            }
        }
        eventWatcher?.processExistingEvents()
        eventWatcher?.start()
    }

    private func scanExistingSessions() {
        let scanner = SessionScanner()
        for session in scanner.discoverSessions() {
            sessionManager.addDiscoveredSession(session)
        }
        updateIcon()
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let count = sessionManager.needsAttentionCount
        if count > 0 {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Needs attention")
            button.image?.isTemplate = false
            // Badge via title
            statusItem?.button?.title = " \(count)"
        } else {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.image?.isTemplate = true
            statusItem?.button?.title = ""
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Views/ SessionNoticer/SessionNoticerApp.swift
git commit -m "feat: add menu bar dropdown with session list and status pills"
```

---

### Task 9: BannerController (Slide-down Notification)

**Files:**
- Create: `SessionNoticer/Banner/BannerController.swift`

- [ ] **Step 1: Implement BannerController**

Create `SessionNoticer/Banner/BannerController.swift`:

```swift
import SwiftUI
import AppKit

class BannerController {
    static let shared = BannerController()

    private var bannerWindow: NSWindow?
    private var hideTimer: Timer?
    private var queue: [Session] = []
    private var isShowing = false

    weak var sessionManager: SessionManager?

    func showBanner(for session: Session?) {
        guard let session else { return }

        if isShowing {
            queue.append(session)
            return
        }

        displayBanner(for: session)
    }

    private func displayBanner(for session: Session) {
        isShowing = true

        guard let screen = NSScreen.main else { return }
        let bannerWidth: CGFloat = 320
        let bannerHeight: CGFloat = 56

        // Position: top center, just below menu bar
        let menuBarHeight: CGFloat = NSStatusBar.system.thickness
        let x = (screen.frame.width - bannerWidth) / 2
        let y = screen.frame.height - menuBarHeight - bannerHeight - 4

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false

        let bannerView = BannerView(
            projectName: session.projectName,
            message: "Needs permission",
            onTap: { [weak self] in
                ITerm2Focuser.focusSession(session, in: self?.sessionManager)
                self?.hideBanner()
            }
        )
        window.contentViewController = NSHostingController(rootView: bannerView)

        // Animate in: slide down from above
        window.alphaValue = 0
        window.setFrame(
            NSRect(x: x, y: y + 20, width: bannerWidth, height: bannerHeight),
            display: false
        )
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(
                NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight),
                display: true
            )
        }

        bannerWindow = window

        // Auto-hide after 4 seconds
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideBanner()
        }
    }

    private func hideBanner() {
        hideTimer?.invalidate()
        hideTimer = nil

        guard let window = bannerWindow else {
            isShowing = false
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.bannerWindow = nil
            self?.isShowing = false

            // Show next queued banner
            if let next = self?.queue.first {
                self?.queue.removeFirst()
                self?.displayBanner(for: next)
            }
        })
    }
}

struct BannerView: View {
    let projectName: String
    let message: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text(projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("Click to focus")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/Banner/
git commit -m "feat: add slide-down banner notification for permission prompts"
```

---

### Task 10: ITerm2Focuser (AppleScript Window Focusing)

**Files:**
- Create: `SessionNoticer/Services/ITerm2Focuser.swift`

- [ ] **Step 1: Implement ITerm2Focuser**

Create `SessionNoticer/Services/ITerm2Focuser.swift`:

```swift
import Foundation
import AppKit

class ITerm2Focuser {
    /// Focus the iTerm2 tab for a session. Pass the SessionManager so resolved TTY can be cached.
    static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
        // Resolve TTY if not cached
        let tty: String
        if let cached = session.tty {
            tty = cached
        } else if let resolved = resolveTTY(pid: session.pid) {
            tty = resolved
            // Cache the resolved TTY back on the session in the manager
            manager?.sessions[session.id]?.tty = resolved
        } else {
            // Fallback: just activate iTerm2
            activateITerm2()
            return
        }

        focusITermTab(tty: tty)
    }

    private static func resolveTTY(pid: Int) -> String? {
        // Use ps to find the TTY of the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, output != "??" {
                return "/dev/" + output
            }
        } catch { }
        return nil
    }

    private static func focusITermTab(tty: String) {
        let script = """
        tell application "iTerm2"
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is "\(tty)" then
                            select aTab
                            select aWindow
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error {
            NSLog("SessionNoticer: AppleScript error: \(error)")
        }
    }

    private static func activateITerm2() {
        let script = """
        tell application "iTerm2"
            activate
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/Services/ITerm2Focuser.swift
git commit -m "feat: add iTerm2 tab focusing via AppleScript"
```

---

### Task 11: First-Launch Orchestration & Integration

**Files:**
- Modify: `SessionNoticer/SessionNoticerApp.swift`

- [ ] **Step 1: Add first-launch check to AppDelegate**

Add first-launch logic to `AppDelegate.applicationDidFinishLaunching`:

```swift
// In applicationDidFinishLaunching, before setupEventWatcher():
if !UserDefaults.standard.bool(forKey: "hooksInstalled") {
    do {
        let installer = HookInstaller()
        try installer.installHooks()

        // Install hook script symlink
        if let bundledScript = Bundle.main.path(forResource: "session-noticer-hook", ofType: nil) {
            try installer.installHookScript(from: bundledScript)
        }

        UserDefaults.standard.set(true, forKey: "hooksInstalled")
    } catch {
        NSLog("SessionNoticer: Failed to install hooks: \(error)")
        // Show alert
        let alert = NSAlert()
        alert.messageText = "Setup Failed"
        alert.informativeText = "Could not install Claude Code hooks: \(error.localizedDescription)"
        alert.runModal()
    }
}
```

- [ ] **Step 2: Add Accessibility permission check**

Add after first-launch check:

```swift
// Check Accessibility permission (needed for AppleScript)
let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let options = [checkOptPrompt: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
if !trusted {
    NSLog("SessionNoticer: Accessibility permission not granted yet")
}
```

- [ ] **Step 3: Build full app and do manual integration test**

```bash
swift build
```

Then run the app and verify:
1. Menu bar icon appears
2. First launch installs hooks in `~/.claude/settings.json`
3. Hook script is symlinked to `~/.local/bin/`
4. Clicking icon shows popover (empty if no sessions)
5. Starting a Claude Code session shows it in the dropdown

- [ ] **Step 4: Commit**

```bash
git add SessionNoticer/SessionNoticerApp.swift
git commit -m "feat: add first-launch setup and accessibility permission check"
```

---

### Task 12: Multiple Instance Prevention + Stale Session Cleanup

**Files:**
- Modify: `SessionNoticer/SessionNoticerApp.swift`
- Modify: `SessionNoticer/Services/SessionManager.swift`

- [ ] **Step 1: Add single-instance enforcement to AppDelegate**

Add at the very beginning of `applicationDidFinishLaunching`:

```swift
// Prevent multiple instances
let bundleId = Bundle.main.bundleIdentifier ?? "com.sessionnoticer"
let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
if running.count > 1 {
    // Another instance is already running — activate it and quit
    if let other = running.first(where: { $0 != NSRunningApplication.current }) {
        other.activate()
    }
    NSApp.terminate(nil)
    return
}
```

- [ ] **Step 2: Add periodic stale session cleanup to SessionManager**

Add to `SessionManager`:

```swift
private var stalePidTimers: [String: Date] = [:] // sessionId -> when PID was first found dead

func startStaleSessionCleanup() {
    Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
        self?.cleanupStaleSessions()
    }
}

private func cleanupStaleSessions() {
    let now = Date()
    for (sessionId, session) in sessions {
        let pidAlive = kill(Int32(session.pid), 0) == 0
        if !pidAlive {
            if let markedAt = stalePidTimers[sessionId] {
                // 30-second grace period elapsed — remove
                if now.timeIntervalSince(markedAt) >= 30 {
                    sessions.removeValue(forKey: sessionId)
                    stalePidTimers.removeValue(forKey: sessionId)
                }
            } else {
                // First time seeing this PID as dead — start grace period
                stalePidTimers[sessionId] = now
            }
        } else {
            // PID came back alive (unlikely but possible) — clear timer
            stalePidTimers.removeValue(forKey: sessionId)
        }
    }
}
```

- [ ] **Step 3: Wire up stale cleanup in AppDelegate**

In `applicationDidFinishLaunching`, after `scanExistingSessions()`:

```swift
sessionManager.startStaleSessionCleanup()
```

- [ ] **Step 4: Build and verify**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/SessionNoticerApp.swift SessionNoticer/Services/SessionManager.swift
git commit -m "feat: add single-instance enforcement and stale session cleanup"
```

---

### Task 13: Icon Assets (Claude Robot)

**Files:**
- Create: `SessionNoticer/Resources/Assets.xcassets/` (or use SF Symbols as placeholder)

- [ ] **Step 1: Create icon helper for dynamic menu bar icon**

For v1, use SF Symbols as a placeholder. Add a helper to `AppDelegate`:

```swift
// Add to AppDelegate
private func iconForState() -> NSImage {
    let count = sessionManager.needsAttentionCount
    let symbolName = count > 0 ? "cpu.fill" : "cpu"
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Session Noticer")!
    image.isTemplate = count == 0 // template = follows system dark/light; non-template for orange tint

    if count > 0 {
        // Apply orange tint
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        return image.withSymbolConfiguration(config)!
    }
    return image
}
```

Update `updateIcon()` to use `iconForState()`.

- [ ] **Step 2: Set up observation on SessionManager for icon updates**

Add Combine subscription in `AppDelegate.applicationDidFinishLaunching`:

```swift
sessionManager.$sessions
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.updateIcon() }
    .store(in: &cancellables)
```

Add `private var cancellables = Set<AnyCancellable>()` and `import Combine` to AppDelegate.

- [ ] **Step 3: Build and verify icon changes**

```bash
swift build
```

Expected: Builds successfully. Icon is gray when no sessions need attention, orange when they do.

- [ ] **Step 4: Commit**

```bash
git add SessionNoticer/
git commit -m "feat: add dynamic menu bar icon with attention state"
```

---

### Task 14: End-to-End Manual Testing

**Files:** None (testing only)

- [ ] **Step 1: Build and run the app**

```bash
swift build
.build/debug/SessionNoticer &
```

- [ ] **Step 2: Verify hook installation**

```bash
cat ~/.claude/settings.json | python3 -m json.tool
```

Expected: Hooks for SessionStart, SessionEnd, Stop, Notification, UserPromptSubmit are present.

- [ ] **Step 3: Simulate a session lifecycle by manually writing event files**

```bash
EVENTS_DIR="$HOME/Library/Application Support/SessionNoticer/events"
mkdir -p "$EVENTS_DIR"

# Simulate SessionStart
cat > "$EVENTS_DIR/$(date +%s%3N)-session_start-$$.json" << 'EOF'
{"event":"session_start","session_id":"test-1","pid":99999,"cwd":"/Users/test/myproject","transcript_path":"","notification_type":"","timestamp":1774312900123}
EOF

sleep 2

# Simulate Notification (permission_prompt)
cat > "$EVENTS_DIR/$(date +%s%3N)-notification-$$.json" << 'EOF'
{"event":"notification","session_id":"test-1","pid":99999,"cwd":"/Users/test/myproject","transcript_path":"","notification_type":"permission_prompt","timestamp":1774312902123}
EOF

sleep 5

# Simulate UserPromptSubmit (back to running)
cat > "$EVENTS_DIR/$(date +%s%3N)-user_prompt-$$.json" << 'EOF'
{"event":"user_prompt","session_id":"test-1","pid":99999,"cwd":"/Users/test/myproject","transcript_path":"","notification_type":"","timestamp":1774312907123}
EOF

sleep 2

# Simulate SessionEnd
cat > "$EVENTS_DIR/$(date +%s%3N)-session_end-$$.json" << 'EOF'
{"event":"session_end","session_id":"test-1","pid":99999,"cwd":"/Users/test/myproject","transcript_path":"","notification_type":"","timestamp":1774312909123}
EOF
```

Expected behavior:
1. "myproject" appears in dropdown as Running
2. Icon turns orange, banner slides down saying "myproject — Needs permission"
3. Banner retracts after 4s, icon shows badge "1"
4. Session goes back to Running, icon turns green
5. Session disappears from list

- [ ] **Step 4: Test with real Claude Code session**

Start a Claude Code session in iTerm2 and verify:
1. Session appears in dropdown with correct project name
2. When Claude asks for permission, banner appears
3. Clicking the session row focuses the correct iTerm2 tab

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete Session Noticer v1 — menu bar Claude Code session monitor"
```
