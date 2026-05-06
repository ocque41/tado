import SwiftUI
import SwiftData

/// Global Todos view — every active todo across every project, the
/// flat-inbox alternative to the per-project drill-down. Redesigned in
/// v0.18 to follow the same `PageHeader` + `SectionRail` grid as the
/// Projects detail page so the two surfaces read as siblings.
///
/// Sections (top → bottom):
///
/// 1. **`PageHeader`** — "Todos" title + meta strip (Status / Total /
///    Active / Awaiting / Last update).
/// 2. **Forward-mode banner** (only when forwarding) — in-line strip
///    above the composer, with an "Stop forwarding" close button.
/// 3. **`SectionRail` "Compose"** — the same composer chrome as
///    `ProjectTodoInput` (header tabs + textarea + footer).
/// 4. **`SectionRail` "Open"** — the list of active todos. Each row
///    keeps `TodoRowView` (shared with the project view's INBOX) so
///    behaviour is identical; the rail provides label / count /
///    filter affordances around it.
struct TodoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @State private var inputText: String = ""
    @State private var composerTab: ComposerTab = .compose
    @FocusState private var isInputFocused: Bool

    private var activeTodos: [TodoItem] {
        todos.filter { $0.listState == .active }
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

    private var inputLineCount: Int {
        max(1, inputText.components(separatedBy: "\n").count)
    }

    private let maxInputLines = 8

    private var inputEditorHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let padding: CGFloat = 20
        let raw = CGFloat(inputLineCount) * lineHeight + padding
        return max(84, min(raw, CGFloat(maxInputLines) * lineHeight + padding))
    }

    var body: some View {
        PageContainer {
            PageHeader(title: "Todos") {
                metaStrip
            }

            // Forward banner — sits between the page header and the
            // first section so it can't be missed when armed.
            if isForwarding, let targetText = forwardTargetText {
                forwardBanner(targetText: targetText)
            }

            SectionRail(
                label: "Compose",
                count: isForwarding ? "forward mode · ⌘⏎ to send" : "scoped · global"
            ) {
                composer
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
            }

            SectionRail(
                label: "Open",
                count: openCountLabel,
                actions: {
                    VStack(alignment: .leading, spacing: 6) {
                        OutlineButton("Done · \(doneCount)", icon: "checkmark.circle", size: .small) {
                            appState.showDoneList = true
                        }
                        OutlineButton("Trash · \(trashedCount)", icon: "trash", size: .small) {
                            appState.showTrashList = true
                        }
                    }
                },
                content: {
                    if activeTodos.isEmpty {
                        emptyState
                    } else {
                        todosList
                    }
                },
                bottomDivider: false
            )
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - Page meta

    private var metaStrip: some View {
        let liveOrAwait = activeTodos.filter {
            $0.status == .running || $0.status == .needsInput || $0.status == .awaitingResponse
        }.count
        return MetaStrip {
            MetaCell(
                key: "Status",
                value: liveOrAwait > 0 ? "● Active" : "○ Idle",
                tint: liveOrAwait > 0 ? Palette.green : Palette.ink3
            )
            MetaCell(key: "Open", value: "\(activeTodos.count)")
            MetaCell(key: "Awaiting", value: "\(awaitingCount)")
            MetaCell(key: "Done", value: "\(doneCount)")
            MetaCell(key: "Trash", value: "\(trashedCount)", trailingDivider: false)
        }
    }

    private var openCountLabel: String {
        if activeTodos.isEmpty { return "Nothing open" }
        let inflight = activeTodos.filter { $0.status == .running }.count
        return "\(activeTodos.count) total · \(inflight) in-flight · \(awaitingCount) awaiting"
    }

    // MARK: - Forward banner

    private func forwardBanner(targetText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Palette.accent)
            Text("FORWARDING TO")
                .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Palette.accent)
            Text(targetText)
                .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            OutlineButton("Cancel", size: .small, variant: .ghost) {
                appState.forwardTargetTodoID = nil
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.accentBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.accentSoft)
                .frame(height: DK.ruleW)
        }
    }

    // MARK: - Composer

    /// Composer chrome for the global Todos page — shares the same
    /// header/body/footer pattern as `ProjectTodoInput.composer` but
    /// without the Team/Agent pickers (a global todo lands as
    /// unassigned and inherits the user's default engine).
    private var composer: some View {
        VStack(spacing: 0) {
            // Header strip
            HStack(spacing: 0) {
                composerTabButton(.compose)
                composerTabButton(.templates)
                composerTabButton(.snippets)
                Spacer()
                Text("UTF-8 · MD")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ink4)
                    .padding(.horizontal, 12)
            }
            .frame(height: 30)
            .background(Palette.bgPage)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }

            // Body — editor for `.compose`, library pane otherwise.
            // Library pane mirrors the editor's height range so the
            // section rail doesn't jump when switching tabs.
            switch composerTab {
            case .compose:
                editorBody
                    .frame(height: inputEditorHeight)
                    .background(Palette.bgElev)
            case .templates:
                ComposerLibraryPane(
                    kind: .templates,
                    projectRoot: nil,
                    projectName: nil,
                    onUse: applyTemplate,
                    onClose: { composerTab = .compose }
                )
                .frame(height: 240)
            case .snippets:
                ComposerLibraryPane(
                    kind: .snippets,
                    projectRoot: nil,
                    projectName: nil,
                    onUse: applySnippet,
                    onClose: { composerTab = .compose }
                )
                .frame(height: 240)
            }

            // Footer
            HStack(spacing: 8) {
                Text("Type a todo, ⌘⏎ to submit · ⇧⏎ for newline")
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                Spacer()
                HStack(spacing: 6) {
                    OutlineButton("Settings", icon: "gearshape", size: .small, variant: .ghost) {
                        appState.showSettings = true
                    }
                    if !inputText.isEmpty {
                        OutlineButton("Cancel", size: .small, variant: .ghost) {
                            inputText = ""
                        }
                    }
                    OutlineButton(
                        isForwarding ? "Send" : "Submit",
                        icon: "plus",
                        size: .small,
                        variant: .accent
                    ) { handleSubmit() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.bgPage)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }
        }
        .background(Palette.bgElev)
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                handleSubmit()
                return .handled
            }
            return .ignored
        }
    }

    /// Body of the editor when `composerTab == .compose`. Lifted
    /// out of the composer so the switch can also render the
    /// library pane in its place.
    private var editorBody: some View {
        ZStack(alignment: .topLeading) {
            if inputText.isEmpty {
                Text(isForwarding ? "Type message to forward…" : "What needs to be done?")
                    .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .padding(.leading, 14)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $inputText)
                .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .scrollContentBackground(.hidden)
                .focused($isInputFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            // Coordinator hint: fades in as the user types
            // `tado <anything>`, signaling that this todo will
            // spawn a Claude coordinator tile (not a generic
            // agent on the canvas).
            if isCoordinatorTyping {
                Text("Coordinator todo — Claude will interpret your intent and drive Tado")
                    .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.accentBg.opacity(0.7))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isCoordinatorTyping)
    }

    /// True when the typed text is recognized as a coordinator
    /// brief by `TodoCommandDetector`. Drives the small inline
    /// hint shown under the input field.
    private var isCoordinatorTyping: Bool {
        if case .coordinator = TodoCommand.detect(inputText) { return true }
        return false
    }

    private func composerTabButton(_ tab: ComposerTab) -> some View {
        let on = composerTab == tab
        return Button(action: { composerTab = tab }) {
            Text(tab.headerLabel.uppercased())
                .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(on ? Palette.ink : Palette.ink4)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(on ? Palette.bgElev : Color.clear)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
                }
        }
        .buttonStyle(.plain)
    }

    private func applyTemplate(_ body: String) {
        inputText = body
        composerTab = .compose
        isInputFocused = true
    }

    private func applySnippet(_ body: String) {
        if inputText.isEmpty {
            inputText = body
        } else {
            inputText.append(inputText.hasSuffix("\n") ? body : "\n" + body)
        }
        composerTab = .compose
        isInputFocused = true
    }

    // MARK: - Empty + list

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No todos yet")
                .font(Font.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Type a task above and press ⌘⏎ to spawn its terminal on the canvas. Each todo becomes one tile.")
                .font(Font.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("INBOX  ·  unassigned by default  ·  drag onto a team via the project page to scope it")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todosList: some View {
        VStack(spacing: 0) {
            ForEach(Array(activeTodos.enumerated()), id: \.element.id) { _, todo in
                TodoRowView(todo: todo)
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: DK.ruleW)
            }
        }
        .background(Palette.bgElev)
        .overlay(
            Rectangle()
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
    }

    // MARK: - Actions

    private func handleSubmit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let targetID = appState.forwardTargetTodoID {
            // Forward mode: send text to existing terminal, then deactivate (one-shot)
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
        modelContext.insert(todo)

        terminalManager.spawnAndWire(todo: todo, engine: settings.engine)

        try? modelContext.save()
        inputText = ""
    }

    /// Spawn a coordinator tile. The agent inside gets
    /// `ProcessSpawner.coordinatorPrompt(brief:todoID:)` instead
    /// of the user's text directly, so it knows to interpret the
    /// brief, drive Tado CLIs, supervise to the human-review
    /// gate, accept on the user's behalf, and exit. The tile
    /// itself is a normal Tado terminal — only its prompt and
    /// `isCoordinator` flag distinguish it.
    private func submitCoordinatorTodo(originalText: String, brief: String) {
        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: originalText, gridIndex: index, canvasPosition: position)
        todo.isCoordinator = true
        // Coordinator tiles inherit no project context — the
        // brief identifies the project, and the coordinator
        // resolves it via `tado-projects`. CWD stays nil so the
        // tile lands in the user's home dir.
        modelContext.insert(todo)
        try? modelContext.save()

        // Replace todo.text with the full coordinator system
        // prompt before spawning so the spawned PTY sees the
        // prompt, not the brief. The original brief is preserved
        // inside the prompt body so the agent has it.
        let prompt = ProcessSpawner.coordinatorPrompt(brief: brief, todoID: todo.id)
        todo.text = prompt
        try? modelContext.save()

        // Pin Claude Opus 4.7. Coordinator reasoning is the
        // load-bearing part of this whole system — we don't
        // honor the user's engine/model picks here.
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
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
