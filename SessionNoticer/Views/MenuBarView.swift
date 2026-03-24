import SwiftUI

struct MenuBarView: View {
    @ObservedObject var sessionManager: SessionManager
    var onSessionTap: (Session) -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if sessionManager.sortedSessions.isEmpty {
                VStack(spacing: 8) {
                    Text("No active sessions")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("Start a Claude Code session to see it here")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                ForEach(sessionManager.sortedSessions) { session in
                    SessionRowView(session: session) {
                        onSessionTap(session)
                    }
                    if session.id != sessionManager.sortedSessions.last?.id {
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
            Divider()
            HStack {
                Button("Quit") { onQuit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}
