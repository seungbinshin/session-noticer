# Session Noticer — Design Spec

A native macOS menu bar app that monitors running Claude Code CLI sessions and notifies the user when a session needs attention.

## Goals

- Show all running Claude Code sessions in a menu bar dropdown
- Notify the user (via slide-down banner) when a session needs permission or input
- Allow clicking a session to focus the iTerm2 tab running it
- Minimal, non-intrusive UX — no system notifications, no popups

## Non-Goals (v1)

- SSH/remote session monitoring (deferred to v2)
- Progress bars or token usage tracking
- Support for terminals other than iTerm2
- VS Code / IDE integration

## Technology

- **Language:** Swift 5+
- **UI Framework:** SwiftUI
- **Target:** macOS 14+ (Sonnet)
- **Distribution:** Direct download (no App Store for v1)

## Architecture

```
┌─────────────────────┐     JSON files      ┌──────────────────────┐
│  Claude Code Hooks  │ ──────────────────→  │  SessionNoticer App  │
│  (shell scripts)    │   ~/Library/App      │  (Swift/SwiftUI)     │
│                     │   Support/           │                      │
│  Installed in       │   SessionNoticer/    │  - FSEvents watcher  │
│  ~/.claude/         │   events/            │  - Menu bar icon     │
│  settings.json      │                      │  - Session state mgr │
└─────────────────────┘                      │  - iTerm2 AppleScript│
                                             └──────────────────────┘
         ┌──────────────────┐
         │  ~/.claude/      │
         │  sessions/*.json │  ← App reads on launch to discover
         │  projects/*/     │    existing sessions & first prompts
         │  *.jsonl         │
         └──────────────────┘
```

### Communication: File-based IPC

Hook scripts write JSON event files to `~/Library/Application Support/SessionNoticer/events/`. The app watches this directory with FSEvents.

Each event file is named `{unix_timestamp_ms}-{event_type}.json` (e.g., `1774312900123-stop.json`). Millisecond precision avoids collisions in practice; if a collision somehow occurs, the hook appends a random 4-char suffix.

Each event file is a single JSON object. The schema varies slightly by event type:

**Common fields (all events):**

```json
{
  "event": "stop",
  "session_id": "abc-123",
  "pid": 12345,
  "cwd": "/Users/you/project",
  "transcript_path": "/Users/you/.claude/projects/.../abc-123.jsonl",
  "timestamp": 1774312900123
}
```

**Notification events include a `notification_type` field** extracted from the Claude Code hook payload:

```json
{
  "event": "notification",
  "notification_type": "permission_prompt",
  "session_id": "abc-123",
  "pid": 12345,
  "cwd": "/Users/you/project",
  "transcript_path": "/Users/you/.claude/projects/.../abc-123.jsonl",
  "timestamp": 1774312900123
}
```

The `notification_type` is either `"permission_prompt"` (Claude needs tool permission) or `"idle_prompt"` (Claude finished and waiting for next prompt). This value comes from the Claude Code Notification hook's stdin JSON payload under the `notification_type` field.

### Session Identity

Sessions are identified by `session_id` (a UUID like `5c7443df-6e5d-47e5-99dc-37cc3b2f63fe`). This is the canonical identifier used as the key in the app's session map.

The PID-named files under `~/.claude/sessions/<PID>.json` are used only for **discovery** — each file contains a `sessionId` field that maps to the canonical session_id. Multiple events for the same session share the same `session_id`. A PID may be reused by the OS, but the `session_id` UUID is globally unique.

### Event Cleanup

The app deletes event files after processing them. On launch, the app processes any event files that accumulated while it was not running, applying them in timestamp order.

## Hook Events & Session State Machine

### Hooks registered in `~/.claude/settings.json`

| Hook Event | What it tells us | Resulting session state |
|---|---|---|
| `SessionStart` | New session began | **Running** |
| `Stop` | Claude finished responding | **Idle** |
| `Notification` (matcher: `permission_prompt`) | Needs tool permission | **Needs Permission** |
| `Notification` (matcher: `idle_prompt`) | Done, waiting for next prompt | **Idle** |
| `UserPromptSubmit` | User sent a new prompt | **Running** |
| `SessionEnd` | Session closed | Remove from list |

### State Machine

**Complete transition table** — every state handles every event:

| Current State | Event | New State |
|---|---|---|
| (none) | `SessionStart` | Running |
| Running | `Stop` | Idle |
| Running | `Notification(permission_prompt)` | Needs Permission |
| Running | `Notification(idle_prompt)` | Idle |
| Running | `SessionEnd` | (removed) |
| Running | `UserPromptSubmit` | Running (no-op) |
| Idle | `UserPromptSubmit` | Running |
| Idle | `SessionEnd` | (removed) |
| Idle | `Stop` | Idle (no-op) |
| Idle | `Notification(permission_prompt)` | Needs Permission |
| Idle | `Notification(idle_prompt)` | Idle (no-op) |
| Needs Permission | `UserPromptSubmit` | Running |
| Needs Permission | `Stop` | Idle |
| Needs Permission | `SessionEnd` | (removed) |
| Needs Permission | `Notification(permission_prompt)` | Needs Permission (no-op) |
| Needs Permission | `Notification(idle_prompt)` | Idle |

`SessionEnd` removes the session from the list regardless of current state. Unknown events are logged and ignored.

### Alert-triggering states

- **Needs Permission** → triggers slide-down banner + orange icon + badge count

### Non-alert states

- **Running** → green icon, no alert
- **Idle** → green icon, no alert

## Menu Bar UI

### Icon States

- **Green Claude robot icon** — all sessions running or idle, no action needed
- **Orange Claude robot icon + badge count** — N sessions need attention

### Dropdown

- Sorted: sessions needing attention at the top, highlighted with orange left border
- Each row shows:
  - **Project name** (bold) — last path component of `cwd`
  - **First prompt** (gray subtitle) — truncated to ~60 chars
  - **Status pill** — colored badge: green "Running", orange "Needs Permission", gray "Idle"
- Footer: Quit and Settings links

### Slide-down Banner

When a session transitions to "Needs Permission":
- A slim banner slides down from the menu bar icon area
- Shows: Claude robot emoji + project name + "Needs permission"
- Clickable — clicking it focuses the iTerm2 tab
- Auto-retracts after ~4 seconds
- If multiple sessions need attention in quick succession, banners queue (not stack)

## iTerm2 Window Focusing

When the user clicks a session row:

1. Look up the session's PID from `~/.claude/sessions/<PID>.json`
2. Resolve the PID's TTY via process tree inspection
3. Use iTerm2 AppleScript API to find and activate the tab owning that TTY:

```applescript
tell application "iTerm2"
    activate
    repeat with aWindow in windows
        repeat with aTab in tabs of aWindow
            repeat with aSession in sessions of aTab
                if tty of aSession is targetTTY then
                    select aTab
                    select aWindow
                    return
                end if
            end repeat
        end repeat
    end repeat
end tell
```

**Edge case:** If the iTerm2 tab was closed but the session file persists, the app checks the PID liveness (`kill(pid, 0)`). If the PID is dead, the session is marked as stale and removed after a 30-second grace period (to allow for brief process restarts).

## First Launch & Setup

### 1. Install hooks

Read `~/.claude/settings.json`, merge in hook entries (preserving existing hooks), write back:

```json
{
  "hooks": {
    "SessionStart": [{ "type": "command", "command": "session-noticer-hook session_start" }],
    "SessionEnd": [{ "type": "command", "command": "session-noticer-hook session_end" }],
    "Stop": [{ "type": "command", "command": "session-noticer-hook stop" }],
    "Notification": [{ "type": "command", "command": "session-noticer-hook notification" }],
    "UserPromptSubmit": [{ "type": "command", "command": "session-noticer-hook user_prompt" }]
  }
}
```

### 2. Install `session-noticer-hook` CLI

A **shell script** bundled inside the app bundle at `SessionNoticer.app/Contents/Resources/session-noticer-hook`. On first launch, the app symlinks it to `~/.local/bin/session-noticer-hook` (creating `~/.local/bin/` if needed and adding it to the user's PATH via a shell profile entry if not already present).

The script does the following:
1. Reads Claude Code's hook JSON payload from **stdin**
2. Extracts `session_id`, `cwd`, and `transcript_path` from the payload
3. Determines the PID of the calling Claude Code process via `$PPID`
4. For `notification` events, extracts `notification_type` from the payload
5. Writes a JSON event file to `~/Library/Application Support/SessionNoticer/events/` named `{unix_timestamp_ms}-{event_type}.json`

```bash
#!/bin/bash
EVENT_TYPE="$1"
EVENTS_DIR="$HOME/Library/Application Support/SessionNoticer/events"
mkdir -p "$EVENTS_DIR"
PAYLOAD=$(cat)
TIMESTAMP=$(date +%s%3N)
SESSION_ID=$(echo "$PAYLOAD" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))")
CWD=$(echo "$PAYLOAD" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))")
TRANSCRIPT=$(echo "$PAYLOAD" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))")
NOTIF_TYPE=$(echo "$PAYLOAD" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('notification_type',''))" 2>/dev/null)

cat > "$EVENTS_DIR/${TIMESTAMP}-${EVENT_TYPE}.json" <<EOF
{
  "event": "$EVENT_TYPE",
  "session_id": "$SESSION_ID",
  "pid": $PPID,
  "cwd": "$CWD",
  "transcript_path": "$TRANSCRIPT",
  "notification_type": "$NOTIF_TYPE",
  "timestamp": $TIMESTAMP
}
EOF
```

### 3. Scan existing sessions

Read `~/.claude/sessions/*.json` to discover already-running Claude Code sessions. For each:
- Check if the PID is alive
- Read the first user prompt from the JSONL transcript
- Add to the session list with state **Running** (assume running if no hook data)

### 4. Request permissions

- **Accessibility** — required for iTerm2 AppleScript window focusing
- Show a prompt with "Open System Settings" button

## Data Model

### In-memory session model

```swift
struct Session {
    let sessionId: String
    let pid: Int
    let cwd: String
    let transcriptPath: String
    var projectName: String      // last component of cwd
    var firstPrompt: String      // truncated to ~60 chars
    var state: SessionState
    var lastUpdated: Date
    var tty: String?             // resolved lazily on first click
}

enum SessionState {
    case running
    case idle
    case needsPermission
}
```

### Persistent storage

None for v1. Sessions are ephemeral — rebuilt from `~/.claude/sessions/` on app launch, kept current via hook events.

### Settings (UserDefaults)

- `bannerDuration: TimeInterval` — how long banner stays visible (default 4s)
- `hooksInstalled: Bool` — whether first-launch setup completed
- `launchAtLogin: Bool` — auto-start on login

## Error Handling & Recovery

### Missed events (app was not running)

On launch, the app processes all event files in the events directory in timestamp order before starting the FSEvents watcher. This catches up on any events that fired while the app was quit.

### Event file cleanup

The app deletes event files immediately after processing. If the events directory grows beyond 1000 files (shouldn't happen normally), the app logs a warning and processes the oldest 1000, deleting them afterward.

### Malformed event JSON

If an event file cannot be parsed as valid JSON, the app logs a warning with the filename and deletes the file. No crash, no retry.

### Missing `~/.claude/settings.json`

If the file does not exist on first launch, the app creates it with only the hooks configuration. If it exists but is not valid JSON, the app shows an error dialog asking the user to fix it manually and provides the path.

### Missing `~/.claude/sessions/` directory

If the directory does not exist, the app starts with an empty session list and relies entirely on hook events for session discovery.

### Multiple app instances

The app uses `NSRunningApplication.runningApplications(withBundleIdentifier:)` to check for an existing instance, plus a file lock at `~/Library/Application Support/SessionNoticer/.lock` as a fallback. If a second instance launches, it activates the first instance and exits.

### PID reuse

If the OS reuses a PID, the `session_id` (UUID) remains unique. The app keys sessions by `session_id`, not PID. A stale PID match is harmless because the session_id won't match.

## Claude Code Hooks API Reference

The hook events used (`SessionStart`, `SessionEnd`, `Stop`, `Notification`, `UserPromptSubmit`) are documented in the [Claude Code hooks reference](https://code.claude.com/docs/en/hooks). Each hook receives a JSON payload on stdin containing at minimum `session_id`, `transcript_path`, and `cwd`. The `Notification` hook additionally provides `notification_type` (`"permission_prompt"` or `"idle_prompt"`).

This spec was validated against Claude Code's hooks system as of March 2026. If Claude Code changes its hook event names or payload format, the `session-noticer-hook` script and `SessionManager` will need corresponding updates.

## Component Breakdown

| Component | Responsibility |
|---|---|
| `SessionNoticerApp` | App entry point, menu bar setup |
| `MenuBarView` | SwiftUI view for dropdown popover |
| `SessionManager` | Owns session list, processes events, state machine |
| `EventWatcher` | FSEvents directory watcher, parses event JSON |
| `HookInstaller` | First-launch setup, modifies `~/.claude/settings.json` |
| `SessionScanner` | Reads `~/.claude/sessions/` and JSONL transcripts |
| `BannerController` | Manages slide-down banner window |
| `iTerm2Focuser` | AppleScript execution for window focusing |
| `session-noticer-hook` | CLI tool invoked by Claude Code hooks |
