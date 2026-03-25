# Session Noticer

A macOS menu bar app that monitors running Claude Code CLI sessions — both local and remote (SSH). Shows session status, notifies when Claude needs permission, and lets you click to jump to the right iTerm2 tab.

## Features

- **Menu bar icon** with status colors (green = active, orange = needs permission)
- **Dropdown** showing all sessions with project name, status pill, and hostname for remote sessions
- **Slide-down banner** when a session needs your permission
- **Click to focus** — jumps to the correct iTerm2 tab (local or SSH)
- **SSH remote tracking** via reverse tunnel — monitor Claude Code sessions on remote machines

## Install (from shared .app)

### 1. Move the app

```bash
# Unzip the shared file
unzip SessionNoticer.zip -d /Applications/
```

### 2. First launch

Right-click `SessionNoticer.app` → **Open** (bypasses Gatekeeper for unsigned apps). Click "Open" in the dialog.

The app will:
- Install hook scripts to `~/.local/bin/`
- Configure Claude Code hooks in `~/.claude/settings.json`
- Request Accessibility permission (needed for iTerm2 tab switching)

### 3. Grant Accessibility permission

When prompted, go to **System Settings → Privacy & Security → Accessibility** and enable **SessionNoticer**.

### 4. Restart Claude Code sessions

Hooks only activate for **new** Claude Code sessions. Restart any running sessions to start tracking.

## Install (from source)

Requires Swift 5.9+ and macOS 14+.

```bash
git clone https://github.com/seungbinshin/session-noticer.git
cd session-noticer
./scripts/build-app.sh
cp -r .build/SessionNoticer.app /Applications/
open /Applications/SessionNoticer.app
```

## SSH Remote Session Setup

Track Claude Code sessions running on remote machines over SSH.

### 1. Setup the remote machine

```bash
# From your Mac (run once per remote machine)
./scripts/session-noticer-setup-remote user@hostname
```

This copies the remote hook script and configures Claude Code hooks on the remote machine.

### 2. Configure SSH reverse tunnel

Add to your **local** `~/.ssh/config`:

```
Host your-remote-hostname
    RemoteForward 9999 localhost:9999
```

This makes the tunnel automatic — no flags to remember.

### 3. SSH and use Claude Code

```bash
ssh your-remote-hostname
claude  # Sessions automatically appear in your menu bar
```

### Troubleshooting SSH

**"remote port forwarding failed for listen port 9999"**

Port 9999 is already in use on the remote machine (stale SSH tunnel). Fix:

```bash
# Find and kill the stale process on the remote
ssh your-remote-hostname "kill \$(lsof -ti :9999) 2>/dev/null"

# Reconnect
ssh your-remote-hostname
```

To prevent stale tunnels, add to the **remote** machine's `/etc/ssh/sshd_config`:

```
ClientAliveInterval 30
ClientAliveCountMax 3
```

## Session States

| Status | Meaning | Icon |
|---|---|---|
| **Running** | Claude is actively working | Green |
| **Done** | Claude finished, waiting for your next prompt | Green |
| **Action** | Claude needs tool permission | Orange + banner |
| **Idle** | Session idle for 60s+ | Green |

## How It Works

1. Claude Code [hooks](https://code.claude.com/docs/en/hooks) fire on session events (start, stop, permission prompt, etc.)
2. **Local sessions:** Hook script writes JSON event files to `~/Library/Application Support/SessionNoticer/events/`
3. **Remote sessions:** Hook script POSTs events to `localhost:9999` via SSH reverse tunnel
4. The app picks up events, updates the session state machine, and reflects changes in the menu bar

## Requirements

- macOS 14+
- iTerm2 (for tab focusing)
- Claude Code CLI with hooks support
- Python 3 (pre-installed on macOS)
