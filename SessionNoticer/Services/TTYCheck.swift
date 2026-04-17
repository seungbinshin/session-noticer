import Foundation

/// Returns whether the given PID has a controlling TTY.
/// Used to filter non-interactive `claude` invocations (API wrappers, SDK subprocesses)
/// from the session list — only real terminal sessions get a TTY.
enum TTYCheck {
    static func hasControllingTTY(pid: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let tty = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !tty.isEmpty && tty != "?" && tty != "??"
        } catch {
            return false
        }
    }
}
