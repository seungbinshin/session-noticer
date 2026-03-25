import Foundation
import AppKit

class ITerm2Focuser {
    static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
        let tty: String
        if let cached = session.tty {
            tty = cached
        } else if let resolved = resolveTTY(pid: session.pid) {
            tty = resolved
            manager?.sessions[session.id]?.tty = resolved
        } else {
            NSLog("SessionNoticer: Could not resolve TTY for PID \(session.pid), falling back to activate")
            activateITerm2()
            return
        }

        NSLog("SessionNoticer: Focusing iTerm2 tab with TTY: \(tty) for \(session.projectName)")
        focusITermTab(tty: tty)
    }

    private static func resolveTTY(pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, output != "??" {
                let tty = "/dev/" + output
                NSLog("SessionNoticer: Resolved PID \(pid) → TTY \(tty)")
                return tty
            }
        } catch {
            NSLog("SessionNoticer: Failed to run ps: \(error)")
        }
        return nil
    }

    private static func focusITermTab(tty: String) {
        // Use tell by process name to avoid issues with app activation
        let script = """
        tell application "iTerm2"
            activate
            repeat with aWindow in windows
                tell aWindow
                    repeat with aTab in tabs
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "\(tty)" then
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
            NSLog("SessionNoticer: Failed to create AppleScript")
            return
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            NSLog("SessionNoticer: AppleScript error: \(error)")
            // Fallback: try using System Events to bring iTerm2 forward
            activateITerm2()
        } else {
            NSLog("SessionNoticer: AppleScript result: \(result.stringValue ?? "nil")")
        }
    }

    private static func activateITerm2() {
        // Use NSWorkspace as a fallback — doesn't need Accessibility permission
        if let iterm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first {
            iterm.activate()
        } else {
            NSWorkspace.shared.launchApplication("iTerm")
        }
    }
}
