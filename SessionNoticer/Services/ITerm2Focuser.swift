import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "focuser")

class ITerm2Focuser {
    static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
        if session.source == .remote {
            focusSSHTab(hostname: session.hostname ?? "")
            return
        }
        let tty: String
        if let cached = session.tty {
            tty = cached
        } else if let resolved = resolveTTY(pid: session.pid) {
            tty = resolved
            manager?.sessions[session.id]?.tty = resolved
        } else {
            logger.warning("Could not resolve TTY for PID \(session.pid), activating iTerm2")
            activateITerm2()
            return
        }

        logger.info("Focusing iTerm2 tab: TTY=\(tty) project=\(session.projectName)")
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
            // Read pipe BEFORE waitUntilExit to avoid potential deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, output != "??" {
                let tty = "/dev/" + output
                logger.debug("Resolved PID \(pid) → TTY \(tty)")
                return tty
            }
        } catch {
            logger.error("Failed to run ps: \(error.localizedDescription)")
        }
        return nil
    }

    private static func focusITermTab(tty: String) {
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
            logger.error("Failed to create AppleScript")
            return
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript error: \(error)")
            activateITerm2()
        } else {
            logger.info("AppleScript result: \(result.stringValue ?? "nil")")
        }
    }

    private static func focusSSHTab(hostname: String) {
        logger.info("Focusing SSH tab for hostname: \(hostname)")

        // Find local ssh process connected to this hostname → get its TTY
        if let tty = resolveSSHTTY(hostname: hostname) {
            logger.info("Found SSH TTY: \(tty) for \(hostname)")
            focusITermTab(tty: tty)
            return
        }

        // Fallback: try matching session name or title containing hostname
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
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            logger.error("SSH AppleScript error: \(error)")
            activateITerm2()
        } else {
            logger.info("SSH name-match result: \(result.stringValue ?? "nil")")
        }
    }

    /// Find the local ssh process connected to a hostname and return its TTY
    private static func resolveSSHTTY(hostname: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // List all processes with their TTY and full command
        process.arguments = ["-eo", "tty,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Look for ssh processes matching the hostname
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Match lines like: ttys005  ssh user@ha-seattle  or  ttys005  ssh ha-seattle
                if trimmed.contains("ssh") && trimmed.contains(hostname) {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if let ttyPart = parts.first, ttyPart.hasPrefix("ttys") {
                        return "/dev/" + ttyPart
                    }
                }
            }
        } catch {
            logger.error("Failed to search for SSH process: \(error.localizedDescription)")
        }
        return nil
    }

    private static func activateITerm2() {
        if let iterm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first {
            iterm.activate()
        }
    }
}
