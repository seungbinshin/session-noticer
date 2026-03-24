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

        let hookEvents = [
            ("SessionStart", "session_start"), ("SessionEnd", "session_end"),
            ("Stop", "stop"), ("Notification", "notification"), ("UserPromptSubmit", "user_prompt"),
        ]

        for (eventName, argName) in hookEvents {
            var eventHooks = hooks[eventName] as? [[String: Any]] ?? []
            let command = "\(hookScriptPath) \(argName)"
            let alreadyExists = eventHooks.contains { ($0["command"] as? String) == command }
            if !alreadyExists {
                eventHooks.append(["type": "command", "command": command])
            }
            hooks[eventName] = eventHooks
        }

        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsPath)
    }

    func installHookScript(from bundlePath: String) throws {
        let targetURL = URL(fileURLWithPath: hookScriptPath)
        let targetDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: hookScriptPath) {
            try FileManager.default.removeItem(atPath: hookScriptPath)
        }
        try FileManager.default.createSymbolicLink(atPath: hookScriptPath, withDestinationPath: bundlePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundlePath)
    }

    private func loadExistingSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
