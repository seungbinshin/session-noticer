# Session Noticer v2 — SSH Remote Session Tracking

Extends v1 to monitor Claude Code sessions running on remote machines over SSH.

## Architecture

```
Remote Machine                          Your Mac
┌─────────────────┐                    ┌──────────────────────┐
│ Claude Code      │                    │  SessionNoticer.app  │
│   ↓ hooks fire   │                    │                      │
│ session-noticer  │   SSH tunnel       │  HTTP listener :9999 │
│  -hook-remote    │──────────────────→ │    ↓                 │
│  (curl localhost │   -R 9999:         │  SessionManager      │
│   :9999/event)   │    localhost:9999  │  (unified local +    │
└─────────────────┘                    │   remote sessions)   │
                                       └──────────────────────┘
```

**Event delivery:**
- Local sessions: file-based IPC (unchanged from v1)
- Remote sessions: SSH reverse tunnel (`-R 9999:localhost:9999`) + HTTP POST

## Components

### 1. Remote Hook Script (`session-noticer-hook-remote`)

Installed on remote machines at `~/.local/bin/`. Same stdin JSON parsing as the local hook script, but:
- Adds `hostname` field (from `$(hostname)`)
- Adds `"source": "remote"` field
- POSTs to `http://localhost:9999/event` via `curl` (2s timeout, fail silently if tunnel not open)
- Atomic — single `python3` call reads stdin, builds event, curls

### 2. HTTP Listener (in app)

Lightweight HTTP server using `NWListener` (Network.framework) on `127.0.0.1:9999`.

- `POST /event` — receives JSON, parses into `HookEvent`, passes to `SessionManager`
- Localhost-only binding (secure — tunnel makes remote appear local)
- Port fallback: if 9999 is taken, try 9998, 9997...
- Malformed JSON → 400, wrong path → 404

### 3. Session Model Changes

```swift
enum SessionSource {
    case local
    case remote
}

// Session gains:
var hostname: String?        // nil = local, "ha-seattle" = remote
var source: SessionSource    // .local or .remote
```

`HookEvent` gains optional `hostname: String?` and `source: String?` fields.

### 4. Setup CLI (`session-noticer setup-remote`)

A shell script you run once per remote machine:

```bash
session-noticer-setup-remote user@hostname
```

It does:
1. `scp` the `session-noticer-hook-remote` script to `~/.local/bin/` on the remote
2. SSH in and merge hooks into remote `~/.claude/settings.json` (same format as local, pointing to the remote hook script)
3. Print instructions to add `-R 9999:localhost:9999` to `~/.ssh/config`

### 5. SSH Config

User adds to `~/.ssh/config`:

```
Host ha-seattle
    RemoteForward 9999 localhost:9999
```

This makes the tunnel automatic — no need to remember `-R` flags.

### 6. Dropdown UI

- Local sessions: `project-name` (unchanged)
- Remote sessions: `hostname: project-name`
- Mixed together, sorted by state priority (same as v1)

### 7. iTerm2 Tab Focusing

- Local: resolve TTY by PID (unchanged)
- Remote: find iTerm2 tab whose session name contains the SSH hostname (e.g., `seungbin@ha-seattle`). Use AppleScript to match against `name of aSession`.

### 8. Stale Remote Session Cleanup

Remote sessions can't use `kill(pid, 0)` since the PID is on a remote machine. Instead:
- If no event received for a remote session in 60 seconds, mark as stale
- Remove after 120 seconds of no events
- A `SessionEnd` event removes immediately (same as local)

## What Doesn't Change

- State machine (Running, Awaiting Response, Needs Permission, Completed)
- Banner notifications
- Icon states (green/yellow/orange/gray)
- Local session handling (file-based IPC)
- All existing v1 functionality

## Open Issue (from v1)

The `Notification` hook with `permission_prompt` may not be firing correctly. Debug logging has been added to the hook script. This affects both local and remote sessions equally — fix applies to both once diagnosed.
