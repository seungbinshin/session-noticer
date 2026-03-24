import Foundation
import AppKit

class ITerm2Focuser {
    /// Focus the iTerm2 tab for a session. Pass the SessionManager so resolved TTY can be cached.
    static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
        let tty: String
        if let cached = session.tty {
            tty = cached
        } else if let resolved = resolveTTY(pid: session.pid) {
            tty = resolved
            manager?.sessions[session.id]?.tty = resolved
        } else {
            activateITerm2()
            return
        }
        focusITermTab(tty: tty)
    }

    private static func resolveTTY(pid: Int) -> String? {
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
        if let error { NSLog("SessionNoticer: AppleScript error: \(error)") }
    }

    private static func activateITerm2() {
        let script = "tell application \"iTerm2\" to activate"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}
