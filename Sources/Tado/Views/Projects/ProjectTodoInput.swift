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
///   - Bottom row — Cmd+Return hint on the right when the buffer is
///     non-empty.
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
        let padding: CGFloat = 8
        return min(CGFloat(inputLineCount) * lineHeight + padding, CGFloat(maxInputLines) * lineHeight + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerRow
            editor
            footerRow
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                submitTodo()
                return .handled
            }
            return .ignored
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

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if inputText.isEmpty {
                Text("New todo for \(project.name)…")
                    .font(Typography.monoBody)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $inputText)
                .font(Typography.monoBody)
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
        }
        .frame(height: inputEditorHeight)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Palette.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footerRow: some View {
        HStack {
            Spacer()
            if inputText.isEmpty {
                Text("Type a todo, ⌘↩ to submit")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Text("⌘↩ to submit")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textSecondary)
            }
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
