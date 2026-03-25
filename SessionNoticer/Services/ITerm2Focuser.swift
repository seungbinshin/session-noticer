import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "focuser")

class ITerm2Focuser {
    static func focusSession(_ session: Session, in manager: SessionManager? = nil) {
        if session.source == .remote {
            focusSSHTab(hostname: session.hostname ?? "", sshClientPort: session.sshClientPort)
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

    private static func focusSSHTab(hostname: String, sshClientPort: String? = nil) {
        logger.info("Focusing SSH tab for hostname: \(hostname), clientPort: \(sshClientPort ?? "nil")")

        // First try: match by SSH client port (unique per connection)
        if let port = sshClientPort, let tty = resolveSSHTTYByPort(port: port) {
            logger.info("Found SSH TTY by port \(port): \(tty)")
            focusITermTab(tty: tty)
            return
        }

        // Second try: match by hostname in process list
        if let tty = resolveSSHTTY(hostname: hostname) {
            logger.info("Found SSH TTY by hostname: \(tty) for \(hostname)")
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

    /// Find the local SSH process by its source port (from SSH_CONNECTION) and return its TTY
    private static func resolveSSHTTYByPort(port: String) -> String? {
        // lsof finds which process owns the local TCP source port
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "tcp:\(port)", "-a", "-c", "ssh", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // lsof -F output: p<PID>\nn<name>\n
            var sshPid: String?
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("p") {
                    sshPid = String(line.dropFirst())
                }
            }

            guard let pid = sshPid else { return nil }

            // Now get this PID's TTY
            let psProcess = Process()
            psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
            psProcess.arguments = ["-p", pid, "-o", "tty="]
            let psPipe = Pipe()
            psProcess.standardOutput = psPipe
            psProcess.standardError = Pipe()
            try psProcess.run()
            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            psProcess.waitUntilExit()
            if let tty = String(data: psData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tty.isEmpty, tty != "??" {
                return "/dev/" + tty
            }
        } catch {
            logger.error("Failed to resolve SSH TTY by port: \(error.localizedDescription)")
        }
        return nil
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
