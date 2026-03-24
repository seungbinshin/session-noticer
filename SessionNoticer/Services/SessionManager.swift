import Foundation
import Combine

class SessionManager: ObservableObject {
    @Published var sessions: [String: Session] = [:]

    var needsAttentionCount: Int {
        sessions.values.filter { $0.state == .needsPermission }.count
    }

    var sortedSessions: [Session] {
        sessions.values.sorted { a, b in
            let order: (SessionState) -> Int = {
                switch $0 {
                case .needsPermission: return 0
                case .running: return 1
                case .idle: return 2
                }
            }
            if order(a.state) != order(b.state) {
                return order(a.state) < order(b.state)
            }
            return a.lastUpdated > b.lastUpdated
        }
    }

    /// Returns true if the event triggered a transition to needsPermission (for banner)
    @discardableResult
    func processEvent(_ event: HookEvent) -> Bool {
        switch event.event {
        case .sessionStart:
            if sessions[event.sessionId] == nil {
                var session = Session(
                    sessionId: event.sessionId,
                    pid: event.pid,
                    cwd: event.cwd,
                    transcriptPath: event.transcriptPath
                )
                session.state = .running
                session.lastUpdated = Date()
                sessions[event.sessionId] = session
            }
            return false

        case .sessionEnd:
            sessions.removeValue(forKey: event.sessionId)
            return false

        case .stop:
            guard sessions[event.sessionId] != nil else { return false }
            sessions[event.sessionId]?.state = .idle
            sessions[event.sessionId]?.lastUpdated = Date()
            return false

        case .notification:
            guard sessions[event.sessionId] != nil else { return false }
            if event.notificationType == .permissionPrompt {
                let wasNotAlready = sessions[event.sessionId]?.state != .needsPermission
                sessions[event.sessionId]?.state = .needsPermission
                sessions[event.sessionId]?.lastUpdated = Date()
                return wasNotAlready
            } else if event.notificationType == .idlePrompt {
                sessions[event.sessionId]?.state = .idle
                sessions[event.sessionId]?.lastUpdated = Date()
            }
            return false

        case .userPrompt:
            guard sessions[event.sessionId] != nil else { return false }
            sessions[event.sessionId]?.state = .running
            sessions[event.sessionId]?.lastUpdated = Date()
            return false
        }
    }

    func addDiscoveredSession(_ session: Session) {
        sessions[session.id] = session
    }

    private var stalePidTimers: [String: Date] = [:]

    func startStaleSessionCleanup() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        for (sessionId, session) in sessions {
            let pidAlive = kill(Int32(session.pid), 0) == 0
            if !pidAlive {
                if let markedAt = stalePidTimers[sessionId] {
                    if now.timeIntervalSince(markedAt) >= 30 {
                        sessions.removeValue(forKey: sessionId)
                        stalePidTimers.removeValue(forKey: sessionId)
                    }
                } else {
                    stalePidTimers[sessionId] = now
                }
            } else {
                stalePidTimers.removeValue(forKey: sessionId)
            }
        }
    }
}
