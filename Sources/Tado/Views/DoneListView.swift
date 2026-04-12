import SwiftUI
import SwiftData

struct DoneListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminalManager.self) private var terminalManager
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]

    private var doneTodos: [TodoItem] {
        todos.filter { $0.listState == .done }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !doneTodos.isEmpty {
                    Button("Empty Dones") { emptyAll() }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                }

                Spacer()

                Text("Done")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))

                Spacer()

                Button("Close") { dismiss() }
                    .font(.system(size: 12, design: .monospaced))
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            if doneTodos.isEmpty {
                Spacer()
                Text("No completed items")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.green)

            Text(todo.text)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1)

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

        terminalManager.spawnAndWire(todo: todo, engine: settings.engine)
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
