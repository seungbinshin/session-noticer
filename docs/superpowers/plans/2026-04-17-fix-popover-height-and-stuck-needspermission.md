# Fix popover height stretching and stuck `needsPermission` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the menu-bar popover from stretching vertically when a single `needsPermission` session is visible, and stop sessions from being stuck on `needsPermission` after the user approves the prompt.

**Architecture:** Two independent, small changes. (1) Move the orange left-edge indicator in `SessionRowView` from an HStack child to a `.overlay(alignment: .leading)` so the Shape's flexible height can no longer inflate the row. (2) Add Claude Code's `PreToolUse` hook to the event pipeline — when it fires on a session in `needsPermission`, transition it back to `running`.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager (`swift test`, `swift build`).

**Spec:** `docs/superpowers/specs/2026-04-17-fix-popover-height-and-stuck-needspermission-design.md`

---

## File Structure

Files modified:
- `SessionNoticer/Models/HookEvent.swift` — add `preToolUse` case to `EventType`
- `SessionNoticer/Services/SessionManager.swift` — handle `preToolUse` in `processEvent`
- `SessionNoticer/Services/HookInstaller.swift` — register `PreToolUse` in settings
- `SessionNoticer/SessionNoticerApp.swift` — bump UserDefaults gate to `hooksInstalled_v2`
- `SessionNoticer/Views/SessionRowView.swift` — move indicator to overlay

Tests added/modified:
- `SessionNoticerTests/HookEventTests.swift` — decode a `pre_tool_use` event
- `SessionNoticerTests/SessionManagerTests.swift` — three new cases around `preToolUse`
- `SessionNoticerTests/HookInstallerTests.swift` — assert `PreToolUse` is installed with the right arg

No new files are created.

---

## Task 1: Add `preToolUse` event and `SessionManager` handling

Adding a case to `EventType` immediately breaks compilation of `SessionManager.processEvent` (its `switch` must stay exhaustive), so the enum change and the handler change must land together. This task covers both, driven by four failing tests (one decoder test + three manager-behavior tests).

**Files:**
- Modify: `SessionNoticer/Models/HookEvent.swift:3-9` (add enum case)
- Modify: `SessionNoticer/Services/SessionManager.swift:43-109` (add switch case)
- Test: `SessionNoticerTests/HookEventTests.swift` (add one new test)
- Test: `SessionNoticerTests/SessionManagerTests.swift` (add three new tests)

- [ ] **Step 1: Write the failing decoder test**

Append to `SessionNoticerTests/HookEventTests.swift` just before the closing brace of `HookEventTests`:

```swift
func testParsePreToolUseEvent() throws {
    let json = """
    {
        "event": "pre_tool_use",
        "session_id": "abc-123",
        "pid": 12345,
        "cwd": "/Users/test/project",
        "transcript_path": "/Users/test/.claude/projects/abc-123.jsonl",
        "notification_type": "",
        "timestamp": 1774312900123
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEvent.self, from: json)
    XCTAssertEqual(event.event, .preToolUse)
    XCTAssertEqual(event.sessionId, "abc-123")
}
```

- [ ] **Step 2: Write the failing manager-behavior tests**

Append these three tests to `SessionNoticerTests/SessionManagerTests.swift` just before the `// MARK: - Helpers` line:

```swift
func testPreToolUseFromNeedsPermissionTransitionsToRunning() {
    manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
    manager.processEvent(makeEvent(type: .notification, sessionId: "s1", notifType: .permissionPrompt))
    XCTAssertEqual(manager.sessions["s1"]?.state, .needsPermission)
    manager.processEvent(makeEvent(type: .preToolUse, sessionId: "s1"))
    XCTAssertEqual(manager.sessions["s1"]?.state, .running)
}

func testPreToolUseIsNoOpForOtherStates() {
    manager.processEvent(makeEvent(type: .sessionStart, sessionId: "s1"))
    // running → preToolUse → still running (no crash, no regression)
    manager.processEvent(makeEvent(type: .preToolUse, sessionId: "s1"))
    XCTAssertEqual(manager.sessions["s1"]?.state, .running)

    // stop → awaitingResponse; preToolUse should not change it
    manager.processEvent(makeEvent(type: .stop, sessionId: "s1"))
    manager.processEvent(makeEvent(type: .preToolUse, sessionId: "s1"))
    XCTAssertEqual(manager.sessions["s1"]?.state, .awaitingResponse)
}

func testPreToolUseForUnknownSessionDoesNotCreateSession() {
    manager.processEvent(makeEvent(type: .preToolUse, sessionId: "ghost"))
    XCTAssertNil(manager.sessions["ghost"])
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL with compile error — `.preToolUse` does not exist on `EventType` (flagged in both test files).

- [ ] **Step 4: Add the enum case**

In `SessionNoticer/Models/HookEvent.swift`, change the `EventType` enum from:

```swift
enum EventType: String, Codable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case stop
    case notification
    case userPrompt = "user_prompt"
}
```

to:

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

- [ ] **Step 5: Add the `preToolUse` case to `processEvent`**

Adding `.preToolUse` to the enum now makes `SessionManager.processEvent`'s `switch event.event` non-exhaustive; the compiler will require this case to compile.

In `SessionNoticer/Services/SessionManager.swift`, inside the `switch event.event` block in `processEvent`, add a new case just before the closing brace of the switch (after the existing `case .userPrompt:` block, before `}` on line 109):

```swift
case .preToolUse:
    guard let existing = sessions[event.sessionId] else { return false }
    if existing.state == .needsPermission {
        sessions[event.sessionId]?.state = .running
        sessions[event.sessionId]?.lastUpdated = Date()
    }
    return false
```

The `guard` ensures we never create sessions from `PreToolUse` (high-frequency event, incomplete metadata). The `if` guard keeps the handler inert for any state other than `needsPermission` — specifically, it avoids touching `lastUpdated` on every tool call, which would interfere with the stale-session cleanup logic.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass, including `testParsePreToolUseEvent`, `testPreToolUseFromNeedsPermissionTransitionsToRunning`, `testPreToolUseIsNoOpForOtherStates`, and `testPreToolUseForUnknownSessionDoesNotCreateSession`.

- [ ] **Step 7: Commit**

```bash
git add SessionNoticer/Models/HookEvent.swift \
        SessionNoticer/Services/SessionManager.swift \
        SessionNoticerTests/HookEventTests.swift \
        SessionNoticerTests/SessionManagerTests.swift
git commit -m "feat: resume needsPermission to running on preToolUse"
```

---

## Task 2: Register `PreToolUse` hook in settings

**Files:**
- Modify: `SessionNoticer/Services/HookInstaller.swift:17-20`
- Test: `SessionNoticerTests/HookInstallerTests.swift:18-39` (update existing) + add one new test

- [ ] **Step 1: Update the existing test to expect `PreToolUse`**

In `SessionNoticerTests/HookInstallerTests.swift`, replace line 27:

```swift
        for event in ["SessionStart", "Stop", "Notification", "UserPromptSubmit", "SessionEnd"] {
```

with:

```swift
        for event in ["SessionStart", "Stop", "Notification", "UserPromptSubmit", "SessionEnd", "PreToolUse"] {
```

- [ ] **Step 2: Add a new test asserting the `pre_tool_use` argument**

Append to `SessionNoticerTests/HookInstallerTests.swift` just before the closing brace of `HookInstallerTests`:

```swift
func testInstallsPreToolUseHookWithCorrectArg() throws {
    let installer = HookInstaller(settingsPath: settingsPath, hookScriptPath: "/usr/local/bin/session-noticer-hook")
    try installer.installHooks()

    let data = try Data(contentsOf: settingsPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hooks = json["hooks"] as! [String: Any]
    let matchers = hooks["PreToolUse"] as! [[String: Any]]
    XCTAssertEqual(matchers.count, 1)
    let hooksList = matchers[0]["hooks"] as! [[String: Any]]
    let command = hooksList[0]["command"] as! String
    XCTAssert(command.hasSuffix(" pre_tool_use"), "PreToolUse command must pass 'pre_tool_use' as arg, got: \(command)")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter HookInstallerTests`
Expected: `testInstallsHooksWithCorrectFormat` FAILS (no matcher for `PreToolUse`), `testInstallsPreToolUseHookWithCorrectArg` FAILS (force unwrap crashes because key is absent).

- [ ] **Step 4: Add `PreToolUse` to the installer's event list**

In `SessionNoticer/Services/HookInstaller.swift`, replace lines 17-20:

```swift
        let hookEvents = [
            ("SessionStart", "session_start"), ("SessionEnd", "session_end"),
            ("Stop", "stop"), ("Notification", "notification"), ("UserPromptSubmit", "user_prompt"),
        ]
```

with:

```swift
        let hookEvents = [
            ("SessionStart", "session_start"), ("SessionEnd", "session_end"),
            ("Stop", "stop"), ("Notification", "notification"), ("UserPromptSubmit", "user_prompt"),
            ("PreToolUse", "pre_tool_use"),
        ]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HookInstallerTests`
Expected: all `HookInstallerTests` PASS.

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add SessionNoticer/Services/HookInstaller.swift SessionNoticerTests/HookInstallerTests.swift
git commit -m "feat: register PreToolUse hook in Claude Code settings"
```

---

## Task 3: Bump install gate so existing users get the new hook

**Files:**
- Modify: `SessionNoticer/SessionNoticerApp.swift:41-55`

No new test — this is a one-liner gate change and the behavior depends on `UserDefaults` persistence which is not covered by the existing test suite. The change is validated by Task 4's manual smoke test (where you'll launch the app and confirm the new hook is registered).

- [ ] **Step 1: Update the UserDefaults key**

In `SessionNoticer/SessionNoticerApp.swift`, replace:

```swift
        if !UserDefaults.standard.bool(forKey: "hooksInstalled") {
            do {
                let installer = HookInstaller()
                try installer.installHooks()
                try installer.installHookScriptFromKnownLocations()
                UserDefaults.standard.set(true, forKey: "hooksInstalled")
                logger.info("Hooks installed successfully")
            } catch {
```

with:

```swift
        if !UserDefaults.standard.bool(forKey: "hooksInstalled_v2") {
            do {
                let installer = HookInstaller()
                try installer.installHooks()
                try installer.installHookScriptFromKnownLocations()
                UserDefaults.standard.set(true, forKey: "hooksInstalled_v2")
                logger.info("Hooks installed successfully (v2)")
            } catch {
```

Leave the rest of the `catch` block and the old `hooksInstalled` key alone — the old key is harmless and removing it serves no purpose. `installHooks()` itself is idempotent (see `HookInstaller.swift:27-38`), so re-running it on an existing `~/.claude/settings.json` will simply add the new `PreToolUse` matcher and leave the other five alone.

- [ ] **Step 2: Build to verify no regressions**

Run: `swift build`
Expected: build succeeds.

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add SessionNoticer/SessionNoticerApp.swift
git commit -m "chore: bump hook install gate to v2 for PreToolUse"
```

---

## Task 4: Move orange indicator to overlay

**Files:**
- Modify: `SessionNoticer/Views/SessionRowView.swift:7-46`

This task has no unit test — the bug is a SwiftUI layout behavior that is reliably reproducible by eye but awkward to assert in an XCTest (would require snapshotting or measuring `NSHostingController` sized output). Instead, the task uses a manual smoke check at the end. The change itself is a pure refactor of the view body; all existing test targets continue to build.

- [ ] **Step 1: Rewrite `SessionRowView.body`**

In `SessionNoticer/Views/SessionRowView.swift`, replace lines 7-45 (the entire `body` property, from `var body: some View {` through the closing `}` before `struct StatusPill`) with:

```swift
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
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

Key differences from the original:
- The `if session.state == .needsPermission { RoundedRectangle... }` block is no longer the first child of the HStack. The HStack now starts with the text VStack.
- A new `.overlay(alignment: .leading) { ... }` modifier sits between `.background` and `.contentShape` and draws the same `RoundedRectangle` indicator pinned to the leading edge.
- The overlay adds `.padding(.vertical, 4)` so the bar is inset slightly from the top/bottom of the row instead of running flush with the padded background.

- [ ] **Step 2: Build and test**

Run: `swift build`
Expected: build succeeds.

Run: `swift test`
Expected: all tests pass (unchanged — this is a view-only change).

- [ ] **Step 3: Manual smoke check**

Run the app from Xcode or via:

```bash
swift run SessionNoticer
```

Trigger a `needsPermission` state (either by running `claude` in a directory you can test against and letting it request a tool that needs permission, or by manually constructing a test event — see `SessionNoticer/Resources/session-noticer-hook` for the payload shape).

Verify:
1. When exactly one `needsPermission` session is in the list, the popover is tight to the content (approximately one row's height plus the "Quit" footer), **not** stretched vertically as in the screenshot in the spec.
2. The orange indicator bar appears on the leading edge of the row and is the height of the row (roughly the text block + 4pt vertical inset), not the whole popover.
3. Sessions in `running`, `awaitingResponse`, `completed`, `idle` states still render without the indicator and without background tint.

Quit the running `swift run` process with `Ctrl+C` when done.

- [ ] **Step 4: Manual smoke check — stuck `needsPermission` recovery**

This validates Tasks 1 + 2 + 3 end-to-end. With the app still installed (or after running `swift run SessionNoticer` once so hooks install):

1. Verify `~/.claude/settings.json` now contains a `PreToolUse` entry:
    ```bash
    /usr/bin/python3 -c "import json; print(json.dumps(list(json.load(open('$HOME/.claude/settings.json'))['hooks'].keys())))"
    ```
    Expected output includes `"PreToolUse"`.
2. Start `claude` in any directory. Issue a prompt that requires a tool that will prompt for permission.
3. When the "Action" pill appears in the menu bar popover, approve the permission prompt in the terminal.
4. Watch the popover — the row should transition from "Action" back to "Running" within a second (on the next `PreToolUse`, which fires immediately as Claude starts the tool call).

- [ ] **Step 5: Commit**

```bash
git add SessionNoticer/Views/SessionRowView.swift
git commit -m "fix: prevent row indicator from stretching popover"
```

---

## Final verification

- [ ] **Step 1: Full test run**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 2: Release build**

Run: `swift build -c release`
Expected: build succeeds with no warnings related to our changes.

- [ ] **Step 3: Confirm all tasks committed**

Run: `git log --oneline main..HEAD`
Expected: four commits — one per task (Tasks 1 through 4).
