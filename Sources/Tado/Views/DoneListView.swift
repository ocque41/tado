import SwiftUI
import SwiftData

struct DoneListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminalManager.self) private var terminalManager
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \Team.createdAt) private var teams: [Team]

    private var doneTodos: [TodoItem] {
        todos.filter { $0.listState == .done }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !doneTodos.isEmpty {
                    Button("Empty Dones") { emptyAll() }
                        .font(Typography.label)
                        .foregroundStyle(Palette.danger)
                        .buttonStyle(.plain)
                }

                Spacer()

                Text("Done")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Button("Close") { dismiss() }
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            if doneTodos.isEmpty {
                Spacer()
                Text("No completed items")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(doneTodos) { todo in
                            doneRow(todo)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
    }

    private func doneRow(_ todo: TodoItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.success)

            Text(todo.displayName)
                .font(Typography.monoDefault)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if let pid = todo.projectID, let pname = projects.first(where: { $0.id == pid })?.name {
                Text("/\(pname)")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Restore button
            Button(action: { restoreTodo(todo) }) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Restore to todo list")

            // Permanent delete
            Button(action: { permanentDelete(todo) }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
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
        for todo in doneTodos {
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
