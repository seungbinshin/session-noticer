# V2 SSH Remote Session Tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend SessionNoticer to monitor Claude Code sessions on remote machines via SSH reverse tunnel, alongside existing local sessions.

**Architecture:** Remote Claude Code hooks POST events to `localhost:9999` via SSH reverse tunnel. The app runs an HTTP listener (Network.framework `NWListener`) on that port, feeding events into the same `SessionManager`. Remote sessions are distinguished by `hostname` and `source` fields. iTerm2 focusing for remote sessions matches tab name by SSH hostname.

**Tech Stack:** Swift 5+, SwiftUI, Network.framework (NWListener), existing v1 codebase.

**Spec:** `docs/superpowers/specs/2026-03-25-v2-ssh-tracking-design.md`

---

## File Structure

```
SessionNoticer/
├── Models/
│   ├── Session.swift                    # MODIFY: add hostname, source fields
│   └── HookEvent.swift                  # MODIFY: add hostname, source fields
├── Services/
│   ├── HTTPEventListener.swift          # CREATE: NWListener HTTP server on :9999
│   ├── SessionManager.swift             # MODIFY: stale remote cleanup (timeout-based)
│   ├── ITerm2Focuser.swift              # MODIFY: SSH tab matching by hostname
│   ├── EventWatcher.swift               # (unchanged)
│   ├── SessionScanner.swift             # (unchanged)
│   └── HookInstaller.swift              # (unchanged)
├── Views/
│   ├── SessionRowView.swift             # MODIFY: show hostname prefix for remote
│   └── MenuBarView.swift                # (unchanged)
├── Banner/
│   └── BannerController.swift           # (unchanged)
├── Resources/
│   ├── session-noticer-hook             # (unchanged — local hook)
│   └── session-noticer-hook-remote      # CREATE: remote hook script (curl-based)
├── SessionNoticerApp.swift              # MODIFY: start HTTP listener
└── Scripts/
    └── session-noticer-setup-remote     # CREATE: one-time remote setup script
```

---

### Task 1: Extend Models (Session + HookEvent)

**Files:**
- Modify: `SessionNoticer/Models/Session.swift`
- Modify: `SessionNoticer/Models/HookEvent.swift`
- Modify: `SessionNoticerTests/HookEventTests.swift`

- [ ] **Step 1: Write failing test for remote HookEvent parsing**

Add to `SessionNoticerTests/HookEventTests.swift`:

```swift
func testParseRemoteEvent() throws {
    let json = """
    {
        "event": "stop",
        "session_id": "remote-123",
        "pid": 5678,
        "cwd": "/home/user/project",
        "transcript_path": "/home/user/.claude/projects/project/remote-123.jsonl",
        "notification_type": "",
        "hostname": "ha-seattle",
        "source": "remote",
        "timestamp": 1774312900123
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEvent.self, from: json)
    XCTAssertEqual(event.hostname, "ha-seattle")
    XCTAssertEqual(event.source, "remote")
}

func testParseLocalEventHasNilHostname() throws {
    let json = """
    {
        "event": "stop",
        "session_id": "local-123",
        "pid": 1234,
        "cwd": "/Users/test/project",
        "transcript_path": "",
        "notification_type": "",
        "timestamp": 1774312900123
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEvent.self, from: json)
    XCTAssertNil(event.hostname)
    XCTAssertNil(event.source)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter HookEventTests
```

Expected: FAIL — `hostname` and `source` not defined on HookEvent.

- [ ] **Step 3: Add fields to HookEvent**

In `SessionNoticer/Models/HookEvent.swift`, add to the struct:

```swift
let hostname: String?
let source: String?
```

Add to `CodingKeys`:

```swift
case hostname
case source
```

In `init(from decoder:)`, after the existing parsing:

```swift
hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
source = (rawSource?.isEmpty == false) ? rawSource : nil
```

In the memberwise `init` extension, add the two new parameters with defaults:

```swift
init(event: EventType, sessionId: String, pid: Int, cwd: String,
     transcriptPath: String, notificationType: NotificationType?, timestamp: Int64,
     hostname: String? = nil, source: String? = nil) {
    // ... existing assignments ...
    self.hostname = hostname
    self.source = source
}
```

- [ ] **Step 4: Add fields to Session**

In `SessionNoticer/Models/Session.swift`, add:

```swift
enum SessionSource {
    case local
    case remote
}
```

Add to `Session` struct:

```swift
var hostname: String?
var source: SessionSource
```

Update `init`:

```swift
self.hostname = nil
self.source = .local
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter HookEventTests
```

Expected: All tests PASS (including 2 new ones).

- [ ] **Step 6: Commit**

```bash
git add SessionNoticer/Models/ SessionNoticerTests/HookEventTests.swift
git commit -m "feat(v2): add hostname and source fields to Session and HookEvent"
```

---

### Task 2: Update SessionManager for Remote Sessions

**Files:**
- Modify: `SessionNoticer/Services/SessionManager.swift`
- Modify: `SessionNoticerTests/SessionManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `SessionNoticerTests/SessionManagerTests.swift`:

```swift
func testRemoteSessionCreatedWithHostname() {
    let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
    manager.processEvent(event)
    XCTAssertEqual(manager.sessions["r1"]?.hostname, "ha-seattle")
    XCTAssertEqual(manager.sessions["r1"]?.source, .remote)
}

func testStaleRemoteSessionRemovedAfterTimeout() {
    let event = makeEvent(type: .sessionStart, sessionId: "r1", hostname: "ha-seattle", source: "remote")
    manager.processEvent(event)

    // Simulate session being old
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
```

Update `makeEvent` helper to accept hostname/source:

```swift
private func makeEvent(
    type: EventType,
    sessionId: String,
    notifType: NotificationType? = nil,
    hostname: String? = nil,
    source: String? = nil
) -> HookEvent {
    HookEvent(
        event: type, sessionId: sessionId, pid: 12345,
        cwd: "/Users/test/project",
        transcriptPath: "/Users/test/.claude/projects/test/\(sessionId).jsonl",
        notificationType: notifType, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
        hostname: hostname, source: source
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionManagerTests
```

- [ ] **Step 3: Update SessionManager**

In `processEvent`, for `.sessionStart`, set hostname and source:

```swift
case .sessionStart:
    if sessions[event.sessionId] == nil {
        var session = Session(
            sessionId: event.sessionId, pid: event.pid,
            cwd: event.cwd, transcriptPath: event.transcriptPath
        )
        session.state = .running
        session.lastUpdated = Date()
        if let hostname = event.hostname, event.source == "remote" {
            session.hostname = hostname
            session.source = .remote
        }
        sessions[event.sessionId] = session
    }
    return false
```

Add remote stale cleanup method:

```swift
func cleanupRemoteStaleSessions() {
    let now = Date()
    for (sessionId, session) in sessions {
        guard session.source == .remote else { continue }
        if now.timeIntervalSince(session.lastUpdated) > 120 {
            sessions.removeValue(forKey: sessionId)
        }
    }
}
```

In `startStaleSessionCleanup`, add remote cleanup to the existing timer callback:

```swift
func startStaleSessionCleanup() {
    Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
        self?.cleanupStaleSessions()
        self?.cleanupRemoteStaleSessions()
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SessionManagerTests
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Services/SessionManager.swift SessionNoticerTests/SessionManagerTests.swift
git commit -m "feat(v2): handle remote sessions in SessionManager with timeout cleanup"
```

---

### Task 3: HTTP Event Listener

**Files:**
- Create: `SessionNoticer/Services/HTTPEventListener.swift`

- [ ] **Step 1: Implement HTTPEventListener**

Create `SessionNoticer/Services/HTTPEventListener.swift`:

```swift
import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "http")

class HTTPEventListener {
    private var listener: NWListener?
    private let port: UInt16
    var onEvent: ((HookEvent) -> Void)?

    init(port: UInt16 = 9999) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.error("Failed to create listener on port \(self.port): \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("HTTP listener ready on port \(self.port)")
            case .failed(let error):
                logger.error("HTTP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Read up to 64KB (more than enough for an event JSON)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            defer { connection.cancel() }

            guard let data, error == nil else {
                logger.warning("Connection error: \(error?.localizedDescription ?? "no data")")
                self?.sendResponse(connection: connection, status: 400, body: "Bad request")
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                self?.sendResponse(connection: connection, status: 400, body: "Invalid encoding")
                return
            }

            // Simple HTTP parsing — find the JSON body after the blank line
            guard request.hasPrefix("POST /event") else {
                self?.sendResponse(connection: connection, status: 404, body: "Not found")
                return
            }

            // Split headers and body
            let parts = request.components(separatedBy: "\r\n\r\n")
            guard parts.count >= 2, let jsonData = parts[1].data(using: .utf8) else {
                self?.sendResponse(connection: connection, status: 400, body: "No body")
                return
            }

            guard let event = try? JSONDecoder().decode(HookEvent.self, from: jsonData) else {
                logger.warning("Failed to parse event JSON from HTTP")
                self?.sendResponse(connection: connection, status: 400, body: "Invalid JSON")
                return
            }

            logger.info("Received remote event: \(event.event.rawValue) from \(event.hostname ?? "unknown")")
            self?.sendResponse(connection: connection, status: 200, body: "OK")
            DispatchQueue.main.async {
                self?.onEvent?(event)
            }
        }
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .idempotent)
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
git add SessionNoticer/Services/HTTPEventListener.swift
git commit -m "feat(v2): add HTTP event listener for remote session events"
```

---

### Task 4: Wire HTTP Listener into AppDelegate

**Files:**
- Modify: `SessionNoticer/SessionNoticerApp.swift`

- [ ] **Step 1: Add HTTPEventListener to AppDelegate**

Add property:

```swift
private var httpListener: HTTPEventListener?
```

Add new method:

```swift
private func setupHTTPListener() {
    httpListener = HTTPEventListener(port: 9999)
    httpListener?.onEvent = { [weak self] event in
        guard let self else { return }
        logger.debug("Remote event: \(event.event.rawValue) for \(event.sessionId)")
        let triggered = self.sessionManager.processEvent(event)
        self.updateIcon()
        if triggered {
            let session = self.sessionManager.sessions[event.sessionId]
            BannerController.shared.showBanner(for: session)
        }
    }
    httpListener?.start()
}
```

Call `setupHTTPListener()` in `applicationDidFinishLaunching`, after `setupEventWatcher()`.

- [ ] **Step 2: Build and verify**

```bash
swift build
```

- [ ] **Step 3: Test manually with curl**

```bash
curl -s -X POST http://localhost:9999/event \
  -H "Content-Type: application/json" \
  -d '{"event":"session_start","session_id":"ssh-test-1","pid":9999,"cwd":"/home/user/project","transcript_path":"","notification_type":"","hostname":"ha-seattle","source":"remote","timestamp":1774312900123}'
```

Check menu bar — should show "ha-seattle: project" in the dropdown.

```bash
# Clean up
curl -s -X POST http://localhost:9999/event \
  -d '{"event":"session_end","session_id":"ssh-test-1","pid":9999,"cwd":"/home/user/project","transcript_path":"","notification_type":"","hostname":"ha-seattle","source":"remote","timestamp":1774312999123}'
```

- [ ] **Step 4: Commit**

```bash
git add SessionNoticer/SessionNoticerApp.swift
git commit -m "feat(v2): wire HTTP listener into AppDelegate for remote events"
```

---

### Task 5: Update SessionRowView for Remote Sessions

**Files:**
- Modify: `SessionNoticer/Views/SessionRowView.swift`

- [ ] **Step 1: Update SessionRowView to show hostname**

Change the project name display:

```swift
VStack(alignment: .leading, spacing: 2) {
    HStack(spacing: 4) {
        if let hostname = session.hostname {
            Text(hostname)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
            Text(":")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        Text(session.projectName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
    }
    if !session.firstPrompt.isEmpty {
        Text(session.firstPrompt)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/Views/SessionRowView.swift
git commit -m "feat(v2): show hostname prefix for remote sessions in dropdown"
```

---

### Task 6: iTerm2 Focuser — SSH Tab Matching

**Files:**
- Modify: `SessionNoticer/Services/ITerm2Focuser.swift`

- [ ] **Step 1: Add SSH tab matching to ITerm2Focuser**

Add a new method for remote sessions and update `focusSession`:

```swift
static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
    if session.source == .remote {
        focusSSHTab(hostname: session.hostname ?? "")
        return
    }
    // ... existing local TTY logic unchanged ...
}

private static func focusSSHTab(hostname: String) {
    logger.info("Focusing SSH tab for hostname: \(hostname)")
    let script = """
    tell application "iTerm2"
        activate
        repeat with aWindow in windows
            tell aWindow
                repeat with aTab in tabs
                    repeat with aSession in sessions of aTab
                        set sessionName to name of aSession
                        if sessionName contains "\(hostname)" then
                            select aTab
                            select aWindow
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
        end repeat
    end tell
    return "not found"
    """
    guard let appleScript = NSAppleScript(source: script) else {
        logger.error("Failed to create SSH AppleScript")
        return
    }
    var error: NSDictionary?
    let result = appleScript.executeAndReturnError(&error)
    if let error {
        logger.error("SSH AppleScript error: \(error)")
        activateITerm2()
    } else {
        logger.info("SSH focus result: \(result.stringValue ?? "nil")")
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/Services/ITerm2Focuser.swift
git commit -m "feat(v2): add SSH tab focusing by hostname matching"
```

---

### Task 7: Remote Hook Script

**Files:**
- Create: `SessionNoticer/Resources/session-noticer-hook-remote`

- [ ] **Step 1: Create the remote hook script**

Create `SessionNoticer/Resources/session-noticer-hook-remote`:

```bash
#!/bin/bash
# session-noticer-hook-remote: Called by Claude Code hooks on remote machines.
# Sends events to local Mac via SSH reverse tunnel.
# Usage: session-noticer-hook-remote <event_type>

set -euo pipefail

EVENT_TYPE="${1:-unknown}"

# Read payload from stdin, add hostname + source, POST to tunnel
cat | /usr/bin/python3 -c "
import sys, json, time, socket, urllib.request, urllib.error

d = json.load(sys.stdin)
ts = int(time.time() * 1000)
event_type = '${EVENT_TYPE}'

event = {
    'event': event_type,
    'session_id': d.get('session_id', 'unknown'),
    'pid': d.get('pid', 0),
    'cwd': d.get('cwd', ''),
    'transcript_path': d.get('transcript_path', ''),
    'notification_type': d.get('notification_type', ''),
    'hostname': socket.gethostname(),
    'source': 'remote',
    'timestamp': ts
}

body = json.dumps(event).encode()
req = urllib.request.Request(
    'http://localhost:9999/event',
    data=body,
    headers={'Content-Type': 'application/json'},
    method='POST'
)

try:
    urllib.request.urlopen(req, timeout=2)
except (urllib.error.URLError, ConnectionRefusedError, OSError):
    pass  # Tunnel not open — fail silently
"
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x SessionNoticer/Resources/session-noticer-hook-remote
git add SessionNoticer/Resources/session-noticer-hook-remote
git commit -m "feat(v2): add remote hook script (curl via reverse tunnel)"
```

---

### Task 8: Remote Setup Script

**Files:**
- Create: `scripts/session-noticer-setup-remote`

- [ ] **Step 1: Create the setup script**

Create `scripts/session-noticer-setup-remote`:

```bash
#!/bin/bash
# Setup SessionNoticer hooks on a remote machine.
# Usage: session-noticer-setup-remote user@hostname
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: session-noticer-setup-remote user@hostname"
    exit 1
fi

REMOTE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$PROJECT_DIR/SessionNoticer/Resources/session-noticer-hook-remote"

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "Error: Cannot find session-noticer-hook-remote at $HOOK_SCRIPT"
    exit 1
fi

echo "Setting up SessionNoticer on $REMOTE..."

# 1. Copy hook script
echo "  Copying hook script..."
ssh "$REMOTE" "mkdir -p ~/.local/bin"
scp "$HOOK_SCRIPT" "$REMOTE:~/.local/bin/session-noticer-hook-remote"
ssh "$REMOTE" "chmod +x ~/.local/bin/session-noticer-hook-remote"

# 2. Configure hooks in remote ~/.claude/settings.json
echo "  Configuring Claude Code hooks..."
ssh "$REMOTE" 'python3 -c "
import json, os

settings_path = os.path.expanduser(\"~/.claude/settings.json\")
os.makedirs(os.path.dirname(settings_path), exist_ok=True)

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.get(\"hooks\", {})
script = os.path.expanduser(\"~/.local/bin/session-noticer-hook-remote\")
events = {
    \"SessionStart\": \"session_start\", \"SessionEnd\": \"session_end\",
    \"Stop\": \"stop\", \"Notification\": \"notification\", \"UserPromptSubmit\": \"user_prompt\"
}

for event_name, arg in events.items():
    command = f\"{script} {arg}\"
    matchers = hooks.get(event_name, [])
    already = any(
        command in str(h.get(\"hooks\", []))
        for h in matchers
    )
    if not already:
        matchers.append({\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": command}]})
    hooks[event_name] = matchers

settings[\"hooks\"] = hooks
with open(settings_path, \"w\") as f:
    json.dump(settings, f, indent=4)

print(\"  Hooks configured.\")
"'

# 3. Extract hostname for SSH config
HOST=$(echo "$REMOTE" | cut -d@ -f2)

echo ""
echo "✅ Setup complete!"
echo ""
echo "Add this to your local ~/.ssh/config to enable automatic tunnel:"
echo ""
echo "  Host $HOST"
echo "    RemoteForward 9999 localhost:9999"
echo ""
echo "Then SSH normally: ssh $REMOTE"
echo "SessionNoticer will track remote Claude Code sessions automatically."
```

- [ ] **Step 2: Make executable, test, and commit**

```bash
chmod +x scripts/session-noticer-setup-remote
git add scripts/session-noticer-setup-remote
git commit -m "feat(v2): add remote setup script for one-time SSH configuration"
```

---

### Task 9: Rebuild .app + End-to-End Test

**Files:** None (build + test only)

- [ ] **Step 1: Run all tests**

```bash
swift test
```

Expected: All tests pass.

- [ ] **Step 2: Rebuild .app bundle**

```bash
./scripts/build-app.sh
cp -r .build/SessionNoticer.app /Applications/
```

- [ ] **Step 3: E2E test with simulated remote events**

```bash
# Start app
open /Applications/SessionNoticer.app

# Simulate remote session via curl
curl -s -X POST http://localhost:9999/event \
  -H "Content-Type: application/json" \
  -d '{"event":"session_start","session_id":"e2e-remote","pid":111,"cwd":"/home/user/my-project","transcript_path":"","notification_type":"","hostname":"ha-seattle","source":"remote","timestamp":'$(python3 -c "import time;print(int(time.time()*1000))")'}'

sleep 2

# Transition to awaiting response
curl -s -X POST http://localhost:9999/event \
  -H "Content-Type: application/json" \
  -d '{"event":"stop","session_id":"e2e-remote","pid":111,"cwd":"/home/user/my-project","transcript_path":"","notification_type":"","hostname":"ha-seattle","source":"remote","timestamp":'$(python3 -c "import time;print(int(time.time()*1000))")'}'

sleep 5

# End session
curl -s -X POST http://localhost:9999/event \
  -H "Content-Type: application/json" \
  -d '{"event":"session_end","session_id":"e2e-remote","pid":111,"cwd":"/home/user/my-project","transcript_path":"","notification_type":"","hostname":"ha-seattle","source":"remote","timestamp":'$(python3 -c "import time;print(int(time.time()*1000))")'}'
```

Expected:
1. "ha-seattle: my-project" appears in dropdown as Running
2. Transitions to "Awaiting Response" (yellow), banner slides down
3. Session removed from list

- [ ] **Step 4: Commit and push**

```bash
git add -A
git commit -m "feat(v2): complete SSH remote session tracking"
git push
```
