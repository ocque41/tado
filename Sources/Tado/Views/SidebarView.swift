import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(terminalManager.sessions.count)")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Palette.surface)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.surfaceElevated)

            Divider()

            if terminalManager.sessions.isEmpty {
                Spacer()
                Text("No active sessions")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(terminalManager.sessions) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }

            Divider()

            if !terminalManager.sessions.isEmpty {
                Button(action: terminateAll) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Terminate All")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .background(Palette.surface)
    }

    private func sessionRow(_ session: TerminalSession) -> some View {
        Button(action: {
            appState.pendingNavigationID = session.todoID
            appState.currentView = .canvas
        }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(for: session))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.todoText)
                        .font(Typography.monoRow)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    Text(CanvasLayout.gridLabel(forIndex: session.gridIndex))
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusColor(for session: TerminalSession) -> Color {
        switch session.status {
        case .pending: return Palette.textTertiary
        case .running: return Palette.accent
        case .needsInput: return Palette.warning
        case .completed: return Palette.success
        case .failed: return Palette.danger
        }
    }

    private func terminateAll() {
        let ids = terminalManager.sessions.map(\.id)
        for id in ids {
            terminalManager.terminateSession(id)
        }
    }
}
