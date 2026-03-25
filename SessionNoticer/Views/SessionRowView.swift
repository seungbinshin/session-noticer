import SwiftUI

struct SessionRowView: View {
    let session: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if session.state == .needsPermission || session.state == .awaitingResponse {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(session.state == .needsPermission ? Color.orange : Color.yellow)
                        .frame(width: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let hostname = session.hostname {
                            Text(hostname)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.blue)
                            Text(":")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    if !session.firstPrompt.isEmpty {
                        Text(session.firstPrompt)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                StatusPill(state: session.state)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                session.state == .needsPermission ? Color.orange.opacity(0.08) :
                session.state == .awaitingResponse ? Color.yellow.opacity(0.06) :
                Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusPill: View {
    let state: SessionState

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .running: return "Running"
        case .awaitingResponse: return "Awaiting Response"
        case .needsPermission: return "Needs Permission"
        case .completed: return "Completed"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .running: return .green
        case .awaitingResponse: return .yellow
        case .needsPermission: return .orange
        case .completed: return .gray
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .running: return .green.opacity(0.15)
        case .awaitingResponse: return .yellow.opacity(0.15)
        case .needsPermission: return .orange.opacity(0.15)
        case .completed: return .gray.opacity(0.15)
        }
    }
}
