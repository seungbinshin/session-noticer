import Foundation

enum EventType: String, Codable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case stop
    case notification
    case userPrompt = "user_prompt"
}

enum NotificationType: String, Codable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
}

struct HookEvent: Codable {
    let event: EventType
    let sessionId: String
    let pid: Int
    let cwd: String
    let transcriptPath: String
    let notificationType: NotificationType?
    let timestamp: Int64
    let hostname: String?
    let source: String?
    let sshClientPort: String?

    enum CodingKeys: String, CodingKey {
        case event
        case sessionId = "session_id"
        case pid
        case cwd
        case transcriptPath = "transcript_path"
        case notificationType = "notification_type"
        case timestamp
        case hostname
        case source
        case sshClientPort = "ssh_client_port"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(EventType.self, forKey: .event)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        pid = try container.decode(Int.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)
        transcriptPath = try container.decode(String.self, forKey: .transcriptPath)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)

        // notification_type may be empty string — treat as nil
        let rawNotifType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        if let raw = rawNotifType, !raw.isEmpty {
            notificationType = NotificationType(rawValue: raw)
        } else {
            notificationType = nil
        }

        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = (rawSource?.isEmpty == false) ? rawSource : nil
        let rawPort = try container.decodeIfPresent(String.self, forKey: .sshClientPort)
        sshClientPort = (rawPort?.isEmpty == false) ? rawPort : nil
    }
}

extension HookEvent {
    init(event: EventType, sessionId: String, pid: Int, cwd: String,
         transcriptPath: String, notificationType: NotificationType?, timestamp: Int64,
         hostname: String? = nil, source: String? = nil, sshClientPort: String? = nil) {
        self.event = event
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.timestamp = timestamp
        self.hostname = hostname
        self.source = source
        self.sshClientPort = sshClientPort
    }
}
