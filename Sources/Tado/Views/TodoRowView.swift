import SwiftUI
import SwiftData

struct TodoRowView: View {
    let todo: TodoItem
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]

    private var projectName: String? {
        guard let pid = todo.projectID else { return nil }
        return projects.first { $0.id == pid }?.name
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            statusIndicator

            // Todo text
            Text(todo.text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(todoStatus == .stale ? .tertiary : .primary)
                .lineLimit(1)

            // Project label
            if let name = projectName {
                Text("/\(name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Queue count
            if let session = terminalManager.session(forTodoID: todo.id),
               !session.promptQueue.isEmpty {
                Text("\(session.promptQueue.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange))
            }

            Spacer()

            // Forward button
            if todoStatus != .stale {
                Button(action: startForwarding) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isForwardTarget ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Forward next prompt to this terminal")
            }

            // Done button
            Button(action: markDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark as done")

            // Trash button
            Button(action: trashTodo) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Move to trash")

            // Canvas coordinates link
            Button(action: navigateToTerminal) {
                Text(todo.gridLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Jump to terminal on canvas")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    // MARK: - Status

    private enum TodoDisplayStatus {
        case running, needsInput, completed, failed, stale
    }

    private var todoStatus: TodoDisplayStatus {
        if let session = terminalManager.session(forTodoID: todo.id) {
            switch session.status {
            case .pending: return .stale
            case .running: return .running
            case .needsInput: return .needsInput
            case .completed: return .completed
            case .failed: return .failed
            }
        }
        // No live session — use persisted status
        switch todo.status {
        case .completed: return .completed
        case .failed: return .failed
        default: return .stale
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch todoStatus {
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .needsInput:
            Circle()
                .fill(.orange)
                .frame(width: 10, height: 10)
                .overlay(
                    Text("!")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                )
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
        case .stale:
            Circle()
                .fill(.gray.opacity(0.4))
                .frame(width: 10, height: 10)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(rowColor)
    }

    private var rowColor: Color {
        switch todoStatus {
        case .running: return .clear
        case .needsInput: return .orange.opacity(0.06)
        case .completed: return .green.opacity(0.06)
        case .failed: return .red.opacity(0.06)
        case .stale: return .clear
        }
    }

    private var isForwardTarget: Bool {
        appState.forwardTargetTodoID == todo.id
    }

    // MARK: - Actions

    private func navigateToTerminal() {
        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    private func startForwarding() {
        if appState.forwardTargetTodoID == todo.id {
            appState.forwardTargetTodoID = nil
        } else {
            appState.forwardTargetTodoID = todo.id
        }
    }

    private func markDone() {
        terminalManager.terminateSessionForTodo(todo.id)
        if appState.forwardTargetTodoID == todo.id {
            appState.forwardTargetTodoID = nil
        }
        todo.listState = .done
        todo.gridIndex = -1
        try? modelContext.save()
    }

    private func trashTodo() {
        terminalManager.terminateSessionForTodo(todo.id)
        if appState.forwardTargetTodoID == todo.id {
            appState.forwardTargetTodoID = nil
        }
        todo.listState = .trashed
        todo.gridIndex = -1
        try? modelContext.save()
    }
}
