import SwiftUI
import SwiftData

struct TodoRowView: View {
    let todo: TodoItem
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @State private var isRenaming = false
    @State private var editName = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var projectName: String? {
        guard let pid = todo.projectID else { return nil }
        return projects.first { $0.id == pid }?.name
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            statusIndicator

            // Todo text
            if isRenaming {
                TextField("Name", text: $editName, onCommit: commitRename)
                    .font(Typography.monoDefault)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(todo.displayName)
                    .font(Typography.monoDefault)
                    .foregroundStyle(todoStatus == .stale ? Palette.textTertiary : Palette.textPrimary)
                    .lineLimit(1)
            }

            // Project label
            if let name = projectName {
                Text("/\(name)")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }

            // Queue count
            if let session = terminalManager.session(forTodoID: todo.id),
               !session.promptQueue.isEmpty {
                Text("\(session.promptQueue.count)")
                    .font(Typography.monoBadge)
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.accent))
            }

            Spacer()

            // Forward button
            if todoStatus != .stale {
                Button(action: startForwarding) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isForwardTarget ? Palette.accent : Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Forward next prompt to this terminal")
            }

            // Done button
            Button(action: markDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Mark as done")

            // Trash button
            Button(action: trashTodo) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Move to trash")

            // Canvas coordinates link
            Button(action: navigateToTerminal) {
                Text(todo.gridLabel)
                    .font(Typography.monoLabel)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Jump to terminal on canvas")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") {
                editName = todo.name ?? ""
                isRenaming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isRenameFieldFocused = true
                }
            }
            Divider()
            Button("Mark as Done", action: markDone)
            Button("Move to Trash", role: .destructive, action: trashTodo)
        }
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
                .fill(Palette.warning)
                .frame(width: 10, height: 10)
                .overlay(
                    Text("!")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(Palette.background)
                )
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.danger)
        case .stale:
            Circle()
                .fill(Palette.textTertiary.opacity(0.5))
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
        case .needsInput: return Palette.warning.opacity(0.08)
        case .completed: return Palette.success.opacity(0.08)
        case .failed: return Palette.danger.opacity(0.08)
        case .stale: return .clear
        }
    }

    private var isForwardTarget: Bool {
        appState.forwardTargetTodoID == todo.id
    }

    // MARK: - Actions

    private func commitRename() {
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.name = trimmed.isEmpty ? nil : trimmed
        isRenameFieldFocused = false
        isRenaming = false
        try? modelContext.save()
    }

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
