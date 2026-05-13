// Relay Todos surface — the default landing page per brief
// section 6.1.
//
// Anatomy (top to bottom):
//
// - Page head: kicker `01 — TODOS`, h1 "Todos".
// - Section A — Compose card: editorial card with multi-line
//   textarea, footer meta + Spawn button.
// - Section B — Recent todos: section head + list of rows.
//
// Data flow is unchanged from `TodoListView.swift`: same `TodoItem`
// + SwiftData store, same submission path through `TerminalManager`,
// same coordinator-todo branch. Only the chrome is redesigned.

import SwiftUI
import SwiftData

struct RelayTodoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.relayTheme) private var theme
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \AppSettings.id) private var settingsList: [AppSettings]

    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    private var activeTodos: [TodoItem] {
        todos.filter { $0.listState == .active }
    }

    private var runningCount: Int {
        activeTodos.filter { $0.status == .running }.count
    }

    private var awaitingCount: Int {
        activeTodos.filter { $0.status == .needsInput || $0.status == .awaitingResponse }.count
    }

    private var doneCount: Int {
        todos.filter { $0.listState == .done }.count
    }

    private var trashedCount: Int {
        todos.filter { $0.listState == .trashed }.count
    }

    private var isForwarding: Bool {
        appState.forwardTargetTodoID != nil
    }

    private var forwardTargetText: String? {
        guard let targetID = appState.forwardTargetTodoID else { return nil }
        return activeTodos.first(where: { $0.id == targetID })?.text
    }

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "01 — TODOS",
                title: "Todos",
                lead: nil,
            )

            if isForwarding, let targetText = forwardTargetText {
                forwardBanner(targetText: targetText)
            }

            composeCard
            recentSection
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - Forward banner

    private func forwardBanner(targetText: String) -> some View {
        HStack(spacing: 12) {
            RelayStatusDot(kind: .needsInput, size: 7)
            Text("FORWARDING TO")
                .font(Typography.sans(size: 9, weight: .semibold))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.terracotta)
            Text(targetText)
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            RelayButton(label: "Cancel", variant: .ghost) {
                appState.forwardTargetTodoID = nil
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.terracotta.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Compose card

    private var composeCard: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 16) {
                // SwiftUI TextEditor inherits ~5pt internal leading
                // padding from NSTextView; line-up the placeholder to
                // the same baseline by matching offsets exactly.
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text(isForwarding
                            ? "Message"
                            : "New todo")
                            .font(Typography.sans(size: 18, weight: .light))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $inputText)
                        .font(Typography.sans(size: 18, weight: .light))
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                        .scrollContentBackground(.hidden)
                        .focused($isInputFocused)
                        .frame(minHeight: 60, maxHeight: 180)
                        .onKeyPress(phases: .down) { keyPress in
                            if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                                handleSubmit()
                                return .handled
                            }
                            return .ignored
                        }
                }

                // Footer hairline
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)

                composeFooter
            }
        }
    }

    private var composeFooter: some View {
        let settings = settingsList.first
        let agentLabel: String = {
            guard let s = settings else { return "AGENT · CLAUDE · SONNET" }
            return "AGENT · \(s.engine.displayName.uppercased())"
        }()
        return HStack(spacing: 12) {
            Text(agentLabel)
                .font(Typography.sans(size: 10, weight: .medium))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Text("·")
                .font(Typography.sans(size: 10, weight: .regular))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
            Text(projectLabel.uppercased())
                .font(Typography.sans(size: 10, weight: .medium))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            RelayButton(
                label: isForwarding ? "Send" : "Spawn",
                variant: .primary,
                action: handleSubmit
            )
        }
    }

    private var projectLabel: String {
        if let id = appState.activeProjectID,
           let p = projects.first(where: { $0.id == id }) {
            return "PROJECT · \(p.name)"
        }
        return "PROJECT · UNASSIGNED"
    }

    // MARK: - Recent section

    private var recentSection: some View {
        RelaySection(
            kicker: "02 — RECENT",
            title: recentTitle,
            content: {
                if activeTodos.isEmpty {
                    emptyState
                } else {
                    todosList
                }
            },
            trailing: {
                RelayInlineLink(label: "View done · trash", arrow: .forward) {
                    appState.showDoneList = true
                }
            }
        )
    }

    private var recentTitle: String {
        let n = activeTodos.count
        return "\(n) \(n == 1 ? "todo" : "todos") · \(runningCount) running"
    }

    private var emptyState: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 16) {
                RelayKicker(text: "EMPTY")
                Text("No todos")
                    .font(RelayType.h2(size: 24))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }
        }
    }

    private var todosList: some View {
        VStack(spacing: 0) {
            ForEach(Array(activeTodos.enumerated()), id: \.element.id) { idx, todo in
                RelayTodoRow(index: idx, todo: todo)
            }
        }
    }

    // MARK: - Submission

    private func handleSubmit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let targetID = appState.forwardTargetTodoID {
            terminalManager.forwardInput(toTodoID: targetID, text: text)
            appState.forwardTargetTodoID = nil
            inputText = ""
            return
        }

        switch TodoCommand.detect(text) {
        case .coordinator(let brief):
            submitCoordinatorTodo(originalText: text, brief: brief)
        case .standardPrompt:
            submitNewTodo(text)
        }
    }

    private func submitNewTodo(_ text: String) {
        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)
        let todo = TodoItem(text: text, gridIndex: index, canvasPosition: position)
        let activeProject = projects.first { $0.id == appState.activeProjectID }
        if let activeProject {
            todo.projectID = activeProject.id
        }
        modelContext.insert(todo)
        terminalManager.spawnAndWire(
            todo: todo,
            engine: settings.engine,
            cwd: activeProject?.rootPath,
            projectName: activeProject?.name
        )
        try? modelContext.save()
        inputText = ""
    }

    private func submitCoordinatorTodo(originalText: String, brief: String) {
        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)
        let todo = TodoItem(text: originalText, gridIndex: index, canvasPosition: position)
        todo.isCoordinator = true
        let activeProject = projects.first { $0.id == appState.activeProjectID }
        if let activeProject {
            todo.projectID = activeProject.id
        }
        modelContext.insert(todo)
        try? modelContext.save()
        let prompt = ProcessSpawner.coordinatorPrompt(brief: brief, todoID: todo.id)
        todo.text = prompt
        try? modelContext.save()
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: activeProject?.rootPath,
            projectName: activeProject?.name,
            modelFlagsOverride: ["--model", ClaudeModel.opus47.rawValue]
        )
        EventBus.shared.publish(TadoEvent.coordinatorSpawned(todoID: todo.id, brief: brief))
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

// MARK: - Row

struct RelayTodoRow: View {
    let index: Int
    let todo: TodoItem

    @Environment(\.relayTheme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover: Bool = false

    var body: some View {
        Button(action: {
            appState.focusedTileTodoID = todo.id
            appState.currentView = .canvas
        }) {
            HStack(spacing: 16) {
                Text(String(format: "%02d", index + 1))
                    .font(Typography.sans(size: 11, weight: .medium))
                    .tracking(RelayTracking.caps(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                    .frame(width: 28, alignment: .leading)

                statusDot

                Text(todo.text)
                    .font(Typography.sans(size: 15, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                statusPill

                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(hover ? RelayPalette.wash(for: theme) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RelayPalette.hairSoft(for: theme))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                hover = newValue
            }
        }
    }

    private var statusDot: some View {
        let kind: RelayStatusKind = {
            switch todo.status {
            case .running:           return .running
            case .needsInput:        return .needsInput
            case .awaitingResponse:  return .needsInput
            case .pending:           return .idle
            case .completed:         return .idle
            case .failed:            return .idle
            }
        }()
        return RelayStatusDot(kind: kind, size: 7)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch todo.status {
        case .running:
            RelayPill(label: "running", variant: .outline)
        case .needsInput:
            RelayPill(label: "needs input", variant: .outline)
        case .awaitingResponse:
            RelayPill(label: "awaiting", variant: .outline)
        case .pending:
            RelayPill(label: "pending", variant: .soft)
        case .completed:
            RelayPill(label: "done", variant: .strike)
        case .failed:
            RelayPill(label: "failed", variant: .strike)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            RelayButton(label: "Forward", variant: .tiny) {
                appState.forwardTargetTodoID = todo.id
            }
            RelayButton(label: "Done", variant: .tiny) {
                todo.listState = .done
                try? modelContext.save()
            }
        }
    }
}
