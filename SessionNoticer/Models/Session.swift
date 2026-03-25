import Foundation

enum SessionSource {
    case local
    case remote
}

enum SessionState {
    case running
    case awaitingResponse   // Claude finished a turn, user needs to read and respond
    case needsPermission    // Claude needs tool approval
    case completed          // Session idle 60s+, task likely done
}

struct Session: Identifiable {
    let id: String  // session_id (UUID)
    let pid: Int
    let cwd: String
    let transcriptPath: String
    var projectName: String
    var firstPrompt: String
    var state: SessionState
    var lastUpdated: Date
    var tty: String?
    var hostname: String?
    var source: SessionSource
    var sshClientPort: String?  // local SSH source port — unique per SSH connection

    init(sessionId: String, pid: Int, cwd: String, transcriptPath: String) {
        self.id = sessionId
        self.pid = pid
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.firstPrompt = ""
        self.state = .running
        self.lastUpdated = Date()
        self.tty = nil
        self.hostname = nil
        self.source = .local
        self.sshClientPort = nil
    }
}
