import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Text("\(terminalManager.sessions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if terminalManager.sessions.isEmpty {
                Spacer()
                Text("No active sessions")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .background(.ultraThinMaterial)
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
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)

                    Text(CanvasLayout.gridLabel(forIndex: session.gridIndex))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        case .pending: return .gray
        case .running: return .blue
        case .needsInput: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func terminateAll() {
        let ids = terminalManager.sessions.map(\.id)
        for id in ids {
            terminalManager.terminateSession(id)
        }
    }
}
