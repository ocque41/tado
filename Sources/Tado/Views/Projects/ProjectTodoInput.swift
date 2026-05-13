import SwiftUI
import SwiftData

/// Project-scoped todo input, rendered as a single card. The detail
/// view places it in the ADD TODO zone between the dispatch card and
/// the todos list.
///
/// Layout:
///   - Pickers row (team + agent) — appears only when the project has
///     teams or discovered agents.
///   - Multi-line text editor, grows to 8 lines max before scrolling.
///   - Bottom row with project context and actions.
///
/// Submission (Cmd+Return or onKeyPress) resolves the terminal engine
/// from the agent's location (.claude/agents → claude, .codex/agents
/// → codex) via `AgentDiscoveryService.resolveEngine`, auto-assigns
/// the team when the selected agent is a unique member of one, spawns
/// the terminal tile, and clears the input. Unchanged behavior from
/// Step 1; only the visual frame is new.
struct ProjectTodoInput: View {
    let project: Project

    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var allTodos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var inputText: String = ""
    @State private var selectedAgentName: String? = nil
    @State private var selectedTeamID: UUID? = nil
    @State private var composerTab: ComposerTab = .compose
    @FocusState private var isFocused: Bool

    private var activeTodos: [TodoItem] {
        allTodos.filter { $0.listState == .active && $0.projectID == project.id }
    }

    private var projectTeams: [Team] {
        teams.filter { $0.projectID == project.id }
    }

    private var availableAgents: [AgentDefinition] {
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)
        if let teamID = selectedTeamID,
           let team = projectTeams.first(where: { $0.id == teamID }) {
            return agents.filter { team.agentNames.contains($0.id) }
        }
        return agents
    }

    private var inputLineCount: Int {
        max(1, inputText.components(separatedBy: "\n").count)
    }

    private let maxInputLines = 8

    private var inputEditorHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let padding: CGFloat = 20
        // Floor of 84 px matches the design's `.composer textarea
        // min-height: 84px` so the composer reads as a true input
        // box even when empty. Ceiling is the original 8-line cap.
        let raw = CGFloat(inputLineCount) * lineHeight + padding
        return max(84, min(raw, CGFloat(maxInputLines) * lineHeight + padding))
    }

    var body: some View {
        // Composer chrome follows the design's `.composer` block:
        // a header strip with tabs + encoding label, a tall textarea
        // body (or library pane on the Templates / Snippets tab),
        // and a footer with project context + Cancel/Submit.
        VStack(alignment: .leading, spacing: 0) {
            composerHeader
            pickerRowIfAvailable
            switch composerTab {
            case .compose:
                editor
            case .templates:
                ComposerLibraryPane(
                    kind: .templates,
                    projectRoot: URL(fileURLWithPath: project.rootPath),
                    projectName: project.name,
                    onUse: applyTemplate,
                    onClose: { composerTab = .compose }
                )
                .frame(height: 240)
            case .snippets:
                ComposerLibraryPane(
                    kind: .snippets,
                    projectRoot: URL(fileURLWithPath: project.rootPath),
                    projectName: project.name,
                    onUse: applySnippet,
                    onClose: { composerTab = .compose }
                )
                .frame(height: 240)
            }
            composerFooter
        }
        .frame(maxWidth: .infinity)
        .background(Palette.bgElev)
        .overlay(
            Rectangle()
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                submitTodo()
                return .handled
            }
            return .ignored
        }
    }

    private var composerHeader: some View {
        HStack(spacing: 0) {
            tabCell(.compose)
            tabCell(.templates)
            tabCell(.snippets)
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
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }

    private func tabCell(_ tab: ComposerTab) -> some View {
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
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(width: DK.ruleW)
                }
        }
        .buttonStyle(.plain)
    }

    private func applyTemplate(_ body: String) {
        inputText = body
        composerTab = .compose
        isFocused = true
    }

    private func applySnippet(_ body: String) {
        if inputText.isEmpty {
            inputText = body
        } else {
            inputText.append(inputText.hasSuffix("\n") ? body : "\n" + body)
        }
        composerTab = .compose
        isFocused = true
    }

    @ViewBuilder
    private var pickerRowIfAvailable: some View {
        if !projectTeams.isEmpty || !availableAgents.isEmpty {
            HStack(spacing: 14) {
                pickerRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.rule.opacity(0.6))
                    .frame(height: DK.ruleW)
            }
        }
    }

    private var composerFooter: some View {
        HStack(spacing: 8) {
            Text("PROJECT · \(project.name)")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                if !inputText.isEmpty {
                    OutlineButton("Cancel", size: .small, variant: .ghost) {
                        inputText = ""
                    }
                }
                OutlineButton(
                    "Submit",
                    icon: "plus",
                    size: .small,
                    variant: .accent
                ) {
                    submitTodo()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.bgPage)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var pickerRow: some View {
        if !projectTeams.isEmpty || !availableAgents.isEmpty {
            HStack(spacing: 12) {
                if !projectTeams.isEmpty {
                    labeledPicker(label: "Team") {
                        Picker("", selection: $selectedTeamID) {
                            Text("No team").tag(nil as UUID?)
                            ForEach(projectTeams) { team in
                                Text(team.name).tag(team.id as UUID?)
                            }
                        }
                        .labelsHidden()
                        .font(Typography.monoCaption)
                        .onChange(of: selectedTeamID) { _, newTeamID in
                            if let newTeamID, let team = projectTeams.first(where: { $0.id == newTeamID }) {
                                if let agent = selectedAgentName, !team.agentNames.contains(agent) {
                                    selectedAgentName = nil
                                }
                            }
                        }
                    }
                }

                if !availableAgents.isEmpty {
                    labeledPicker(label: "Agent") {
                        Picker("", selection: $selectedAgentName) {
                            Text("No agent").tag(nil as String?)
                            ForEach(availableAgents) { agent in
                                Text(agent.name).tag(agent.id as String?)
                            }
                        }
                        .labelsHidden()
                        .font(Typography.monoCaption)
                    }
                }

                Spacer()
            }
        }
    }

    private func labeledPicker<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
            content()
                .frame(width: 130)
        }
    }

    /// The textarea body of the composer. Drawn flat against the
    /// composer's outer border (no separate inset card) so the whole
    /// composer reads as a single rectangle the way the design's
    /// `.composer textarea` does — header / body / footer stacked
    /// inside one frame.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if inputText.isEmpty {
                Text("New todo for \(project.name)…")
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
                .focused($isFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .frame(height: inputEditorHeight)
        .background(Palette.bgElev)
    }

    /// _Legacy footer (deprecated — the composerFooter view replaces
    /// this; kept as a stub-free placeholder to keep the file diff
    /// minimal across the design migration). Removed in favour of
    /// `composerFooter` directly inside `body`._
    @ViewBuilder
    private var footerRow: some View {
        HStack {
            Spacer()
            Text("PROJECT · \(project.name)")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: - Submit

    private func submitTodo() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: text, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        todo.agentName = selectedAgentName

        var effectiveTeamID = selectedTeamID
        if effectiveTeamID == nil, let agentName = selectedAgentName {
            effectiveTeamID = projectTeams.first { $0.agentNames.contains(agentName) }?.id
        }
        todo.teamID = effectiveTeamID
        modelContext.insert(todo)

        // Smart engine resolution: agent's parent directory determines harness.
        // .claude/agents/<name>.md → claude, .codex/agents/<name>.md → codex.
        // Falls back to user's default engine when agent is not found or not selected.
        let resolvedEngine: TerminalEngine
        if let agentName = selectedAgentName {
            resolvedEngine = AgentDiscoveryService.resolveEngine(agentName: agentName, projectRoot: project.rootPath) ?? settings.engine
        } else {
            resolvedEngine = settings.engine
        }

        let team = effectiveTeamID.flatMap { tid in teams.first { $0.id == tid } }
        terminalManager.spawnAndWire(
            todo: todo,
            engine: resolvedEngine,
            cwd: project.rootPath,
            agentName: selectedAgentName,
            projectName: project.name,
            teamName: team?.name,
            teamID: team?.id,
            teamAgents: team?.agentNames
        )

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
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }
}
