import Foundation

enum Config {
    /// Port used for the HTTP event listener (local) and SSH reverse tunnel (remote)
    static let httpPort: UInt16 = {
        if let envPort = ProcessInfo.processInfo.environment["SESSION_NOTICER_PORT"],
           let port = UInt16(envPort) {
            return port
        }
        return 9999
    }()

    /// Directory name for event files under ~/Library/Application Support/
    static let appSupportDirName = "SessionNoticer"

    /// Events subdirectory under Application Support
    static let eventsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appSupportDirName)/events")
    }()
}
