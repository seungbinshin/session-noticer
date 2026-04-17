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
                case .awaitingResponse: return 1
                case .running: return 2
                case .completed: return 3
                case .idle: return 4
                }
            }
            if order(a.state) != order(b.state) {
                return order(a.state) < order(b.state)
            }
            return a.lastUpdated > b.lastUpdated
        }
    }

    /// Returns true if the event triggered a state that needs user attention (for banner)
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
                if let hostname = event.hostname, event.source == "remote" {
                    session.hostname = hostname
                    session.source = .remote
                    session.sshClientPort = event.sshClientPort
                }
                sessions[event.sessionId] = session
            } else {
                // Session already discovered — update lastUpdated and state
                sessions[event.sessionId]?.state = .running
                sessions[event.sessionId]?.lastUpdated = Date()
            }
            return false

        case .sessionEnd:
            sessions.removeValue(forKey: event.sessionId)
            return false

        case .stop:
            guard sessions[event.sessionId] != nil else {
                createSessionFromEvent(event)
                sessions[event.sessionId]?.state = .awaitingResponse
                return false
            }
            sessions[event.sessionId]?.state = .awaitingResponse
            sessions[event.sessionId]?.lastUpdated = Date()
            return false

        case .notification:
            guard sessions[event.sessionId] != nil else {
                createSessionFromEvent(event)
                if event.notificationType == .permissionPrompt {
                    sessions[event.sessionId]?.state = .needsPermission
                    return true
                }
                return false
            }
            if event.notificationType == .permissionPrompt {
                let wasNotAlready = sessions[event.sessionId]?.state != .needsPermission
                sessions[event.sessionId]?.state = .needsPermission
                sessions[event.sessionId]?.lastUpdated = Date()
                return wasNotAlready
            } else if event.notificationType == .idlePrompt {
                sessions[event.sessionId]?.state = .completed
                sessions[event.sessionId]?.lastUpdated = Date()
            }
            return false

        case .userPrompt:
            guard sessions[event.sessionId] != nil else {
                createSessionFromEvent(event)
                return false
            }
            sessions[event.sessionId]?.state = .running
            sessions[event.sessionId]?.lastUpdated = Date()
            return false
        }
    }

    /// Create a session from any hook event (for sessions the app didn't see start).
    /// Deduplicates: if a session with the same CWD already exists under a different ID
    /// (e.g., scanner used PID-file ID, hook uses conversation ID), replace the old one.
    private func createSessionFromEvent(_ event: HookEvent) {
        // Remove any existing session with the same CWD to prevent duplicates
        // (PID-file sessionId often differs from hook sessionId after resume)
        let existingKey = sessions.first(where: { $0.value.cwd == event.cwd })?.key
        if let key = existingKey, key != event.sessionId {
            sessions.removeValue(forKey: key)
        }

        var session = Session(
            sessionId: event.sessionId, pid: event.pid,
            cwd: event.cwd, transcriptPath: event.transcriptPath
        )
        session.state = .running
        session.lastUpdated = Date()
        if let hostname = event.hostname, event.source == "remote" {
            session.hostname = hostname
            session.source = .remote
        }
        sessions[event.sessionId] = session
    }

    func addDiscoveredSession(_ session: Session) {
        sessions[session.id] = session
    }

    private var stalePidTimers: [String: Date] = [:]

    func cleanupRemoteStaleSessions() {
        let now = Date()
        for (sessionId, session) in sessions {
            guard session.source == .remote else { continue }
            guard session.state != .idle else { continue }
            // Mark as idle after timeout instead of removing
            let timeout: TimeInterval
            switch session.state {
            case .completed, .running, .awaitingResponse, .needsPermission:
                timeout = 1800    // 30 minutes for all active states
            case .idle:
                continue
            }
            if now.timeIntervalSince(session.lastUpdated) > timeout {
                sessions[sessionId]?.state = .idle
            }
        }
    }

    func startStaleSessionCleanup() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.cleanupStaleSessions()
            self?.cleanupRemoteStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        for (sessionId, session) in sessions {
            // Only check local sessions — remote PIDs are from another machine
            guard session.source == .local else { continue }
            guard session.state != .idle else { continue }
            let pidAlive = kill(Int32(session.pid), 0) == 0
            if !pidAlive {
                if let markedAt = stalePidTimers[sessionId] {
                    if now.timeIntervalSince(markedAt) >= 30 {
                        sessions[sessionId]?.state = .idle
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
