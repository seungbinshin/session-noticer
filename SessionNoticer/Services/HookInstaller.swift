import Foundation

class HookInstaller {
    private let settingsPath: URL
    private let hookScriptPath: String

    init(settingsPath: URL? = nil, hookScriptPath: String? = nil) {
        self.settingsPath = settingsPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        self.hookScriptPath = hookScriptPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/session-noticer-hook").path
    }

    func installHooks() throws {
        var settings = loadExistingSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Claude Code hook format: each event is an array of { "matcher": "", "hooks": [...] }
        let hookEvents = [
            ("SessionStart", "session_start"), ("SessionEnd", "session_end"),
            ("Stop", "stop"), ("Notification", "notification"), ("UserPromptSubmit", "user_prompt"),
        ]

        for (eventName, argName) in hookEvents {
            let command = "\(hookScriptPath) \(argName)"
            var matchers = hooks[eventName] as? [[String: Any]] ?? []

            // Check if our hook already exists in any matcher entry
            let alreadyExists = matchers.contains { matcher in
                guard let hooksList = matcher["hooks"] as? [[String: Any]] else { return false }
                return hooksList.contains { ($0["command"] as? String) == command }
            }

            if !alreadyExists {
                // Add a new matcher entry with empty matcher (matches all) and our hook
                matchers.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": command]]
                ])
            }
            hooks[eventName] = matchers
        }

        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsPath)
    }

    func installHookScript(from sourcePath: String) throws {
        let targetURL = URL(fileURLWithPath: hookScriptPath)
        let targetDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: hookScriptPath) {
            try FileManager.default.removeItem(atPath: hookScriptPath)
        }
        // Copy instead of symlink — works for both .app bundles and SPM builds
        try FileManager.default.copyItem(atPath: sourcePath, toPath: hookScriptPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
    }

    /// Install hook script by searching known locations (bundle, project dir, executable dir)
    func installHookScriptFromKnownLocations() throws {
        // Try Bundle.main first (.app bundle)
        if let bundled = Bundle.main.path(forResource: "session-noticer-hook", ofType: nil) {
            try installHookScript(from: bundled)
            return
        }

        // Try relative to the executable (SPM builds: .build/debug/SessionNoticer)
        let executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let projectCandidates = [
            // From .build/debug/ → project root
            executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SessionNoticer/Resources/session-noticer-hook"),
            // Direct sibling
            executableURL.deletingLastPathComponent()
                .appendingPathComponent("session-noticer-hook"),
        ]

        for candidate in projectCandidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                try installHookScript(from: candidate.path)
                return
            }
        }

        // Already installed? Check if target exists and is executable
        if FileManager.default.isExecutableFile(atPath: hookScriptPath) {
            return // Already installed
        }

        throw NSError(domain: "SessionNoticer", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "Could not find session-noticer-hook script. Please reinstall the app."])
    }

    private func loadExistingSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
