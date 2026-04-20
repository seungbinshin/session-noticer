# Fix popover height stretching and stuck `needsPermission` state

## Problems

**1. Popover stretches vertically with a single `needsPermission` session.**
`SessionRowView` draws the left orange indicator as `RoundedRectangle(...).frame(width: 3)` — a SwiftUI Shape with no height constraint. Shapes are flexible in both axes, so the bar grows to fill available vertical space. Inside the HStack → row → MenuBarView → NSHostingController chain, that flexibility propagates upward and the popover ends up far taller than its content requires.

**2. Sessions stay stuck on `needsPermission` after the user approves.**
`needsPermission` is entered via the `Notification` hook (`permission_prompt`). Claude Code emits no hook when the user approves the prompt, so the state persists until the next `stop`, `user_prompt`, or `session_end` event. During active tool execution the row keeps showing the orange "Action" pill even though the session is running.

## Goals

- Row height is driven by text content; the indicator cannot stretch layout.
- `needsPermission` transitions back to `running` as soon as Claude resumes executing tools.
- Existing users receive the new hook automatically on the next app launch.

## Non-goals

- No `PostToolUse` hook. `PreToolUse` fires before every tool call and is sufficient to detect resumed execution.
- No time-based decay for `needsPermission`. The hook signal is authoritative.
- No redistribution mechanism for the remote hook script. The script itself does not change; it forwards `$1` as the event type unchanged.

## Design

### Fix 1 — Indicator as overlay (`SessionRowView.swift`)

Move the orange bar out of the HStack and into `.overlay(alignment: .leading)` applied to the padded row. Overlays are sized by their parent, which is the HStack's intrinsic size (driven by the text VStack). The Shape keeps its flexible height behavior but is now bounded.

```swift
var body: some View {
    Button(action: onTap) {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) { /* hostname + projectName + firstPrompt */ }
            Spacer()
            StatusPill(state: session.state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(session.state == .needsPermission ? Color.orange.opacity(0.08) : Color.clear)
        .overlay(alignment: .leading) {
            if session.state == .needsPermission {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

The leading 8pt that the HStack used to give the bar is gone; the overlay sits flush against the row's leading edge, which visually matches the screenshot's original intent.

### Fix 2 — `PreToolUse` hook

**`HookEvent.swift`**

Add the case:
```swift
enum EventType: String, Codable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case stop
    case notification
    case userPrompt = "user_prompt"
    case preToolUse = "pre_tool_use"
}
```

**`HookInstaller.swift`**

Append to the `hookEvents` list:
```swift
("PreToolUse", "pre_tool_use"),
```

**`SessionManager.processEvent`**

Add a case:
```swift
case .preToolUse:
    guard let existing = sessions[event.sessionId] else { return false }
    if existing.state == .needsPermission {
        sessions[event.sessionId]?.state = .running
        sessions[event.sessionId]?.lastUpdated = Date()
    }
    return false
```

No session creation on `preToolUse` — it is high-frequency and a session without prior context would be incomplete. If the app missed the session start, the next `stop`, `notification`, or `userPrompt` will create it through the existing `createSessionFromEvent` path.

**Hook scripts**

No changes. Both `session-noticer-hook` and `session-noticer-hook-remote` forward `$1` verbatim as the event type when building the JSON payload.

### Migration

`SessionNoticerApp.applicationDidFinishLaunching` gates installation on `UserDefaults.standard.bool(forKey: "hooksInstalled")`. Existing users have this set to `true` and would not get the new `PreToolUse` hook.

Bump the gate key:
```swift
if !UserDefaults.standard.bool(forKey: "hooksInstalled_v2") {
    try installer.installHooks()
    try installer.installHookScriptFromKnownLocations()
    UserDefaults.standard.set(true, forKey: "hooksInstalled_v2")
}
```

`installHooks()` is already idempotent — its `alreadyExists` check will leave existing matcher entries untouched and only append the new `PreToolUse` entry.

The old `hooksInstalled` key is left in place; removing it is unnecessary and harmless.

## Testing

- **`HookEventTests`** — decode a JSON payload with `"event": "pre_tool_use"` and assert `event == .preToolUse`.
- **`SessionManagerTests`**
  - A `preToolUse` event on a session in `needsPermission` transitions it to `running` and updates `lastUpdated`.
  - A `preToolUse` event on a session in `running` / `awaitingResponse` / `completed` / `idle` is a no-op (state unchanged).
  - A `preToolUse` event for an unknown session id does not create a session.
- **`HookInstallerTests`** — after `installHooks()`, `settings.json` contains a `PreToolUse` matcher entry pointing at the hook script with argument `pre_tool_use`.

Existing tests should continue to pass.

## Risks

- **`PreToolUse` volume.** It fires on every tool call. The handler is O(1) and the `guard ... == .needsPermission` short-circuits for the common case, but this is worth keeping in mind if event-log volume or file-watcher churn becomes noticeable.
- **`hooksInstalled_v2` versioning debt.** Future hook additions will need another bump. Acceptable for now; a more durable fix (remove the gate and rely on `installHooks()`'s own idempotence) can follow separately.
