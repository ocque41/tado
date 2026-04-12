import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    private var activeTodos: [TodoItem] {
        todos.filter { $0.listState == .active }
    }

    private var isForwarding: Bool {
        appState.forwardTargetTodoID != nil
    }

    private var forwardTargetText: String? {
        guard let targetID = appState.forwardTargetTodoID else { return nil }
        return activeTodos.first(where: { $0.id == targetID })?.text
    }

    var body: some View {
        VStack(spacing: 0) {
            // Forward mode banner
            if isForwarding, let targetText = forwardTargetText {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Forwarding to:")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(targetText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button(action: { appState.forwardTargetTodoID = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))

                Divider()
            }

            // Input field
            HStack(spacing: 12) {
                Button(action: { appState.showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (Cmd+M)")

                TextField(
                    isForwarding ? "Type message to forward..." : "What needs to be done?",
                    text: $inputText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .focused($isInputFocused)
                .onSubmit {
                    handleSubmit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            Divider()

            // Todo list
            if activeTodos.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No todos yet")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Type a task and press Enter to start")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activeTodos) { todo in
                            TodoRowView(todo: todo)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .onAppear {
            isInputFocused = true
        }
    }

    private func handleSubmit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let targetID = appState.forwardTargetTodoID {
            // Forward mode: send text to existing terminal, then deactivate (one-shot)
            terminalManager.forwardInput(toTodoID: targetID, text: text)
            appState.forwardTargetTodoID = nil
            inputText = ""
        } else {
            // Normal mode: create new todo + terminal
            submitNewTodo(text)
        }
    }

    private func submitNewTodo(_ text: String) {
        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: text, gridIndex: index, canvasPosition: position)
        modelContext.insert(todo)

        terminalManager.spawnAndWire(todo: todo, engine: settings.engine)

        try? modelContext.save()
        inputText = ""
    }

    private func nextAvailableGridIndex() -> Int {
        let usedIndices = Set(activeTodos.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }
        return index
    }

    private func fetchOrCreateSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }
}
