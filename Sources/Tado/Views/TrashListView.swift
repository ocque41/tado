import SwiftUI
import SwiftData

struct TrashListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminalManager.self) private var terminalManager
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \Team.createdAt) private var teams: [Team]

    private var trashedTodos: [TodoItem] {
        todos.filter { $0.listState == .trashed }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !trashedTodos.isEmpty {
                    Button("Empty Trash") { emptyAll() }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                }

                Spacer()

                Text("Trash")
                    .font(Typography.title)

                Spacer()

                Button("Close") { dismiss() }
                    .font(.system(size: 12, design: .monospaced))
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            if trashedTodos.isEmpty {
                Spacer()
                Text("Trash is empty")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(trashedTodos) { todo in
                            trashRow(todo)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
    }

    private func trashRow(_ todo: TodoItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 14))
                .foregroundStyle(.gray)

            Text(todo.displayName)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1)

            if let pid = todo.projectID, let pname = projects.first(where: { $0.id == pid })?.name {
                Text("/\(pname)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Restore button
            Button(action: { restoreTodo(todo) }) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Restore to todo list")

            // Permanent delete
            Button(action: { permanentDelete(todo) }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete permanently")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func restoreTodo(_ todo: TodoItem) {
        let activeTodos = todos.filter { $0.listState == .active }
        let usedIndices = Set(activeTodos.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }

        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        todo.listState = .active
        todo.gridIndex = index
        todo.canvasX = position.x
        todo.canvasY = position.y
        todo.terminalLog = ""

        let project = todo.projectID.flatMap { pid in projects.first { $0.id == pid } }
        let team = todo.teamID.flatMap { tid in teams.first { $0.id == tid } }
        terminalManager.spawnAndWire(todo: todo, engine: settings.engine, cwd: project?.rootPath, agentName: todo.agentName, projectName: project?.name, teamName: team?.name, teamID: team?.id, teamAgents: team?.agentNames)
        try? modelContext.save()
    }

    private func permanentDelete(_ todo: TodoItem) {
        modelContext.delete(todo)
        try? modelContext.save()
    }

    private func emptyAll() {
        for todo in trashedTodos {
            modelContext.delete(todo)
        }
        try? modelContext.save()
    }

    private func fetchOrCreateSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }
}
