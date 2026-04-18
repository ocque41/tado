import SwiftUI
import SwiftData

/// Project-scoped todo input. Lives inside `ProjectDetailView`; owns
/// its own input text + pickers (team / agent). On Cmd+Return, spawns
/// a terminal tile for the new todo with smart engine resolution via
/// `AgentDiscoveryService.resolveEngine` and auto-team assignment
/// (if an agent is picked but no team, the unique team containing
/// that agent is selected automatically).
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
        VStack(spacing: 6) {
            // Pickers row
            if !projectTeams.isEmpty || !availableAgents.isEmpty {
                HStack(spacing: 10) {
                    if !projectTeams.isEmpty {
                        Picker("", selection: $selectedTeamID) {
                            Text("No team").tag(nil as UUID?)
                            ForEach(projectTeams) { team in
                                Text(team.name).tag(team.id as UUID?)
                            }
                        }
                        .frame(width: 120)
                        .font(Typography.monoCaption)
                        .onChange(of: selectedTeamID) { _, newTeamID in
                            if let newTeamID, let team = projectTeams.first(where: { $0.id == newTeamID }) {
                                if let agent = selectedAgentName, !team.agentNames.contains(agent) {
                                    selectedAgentName = nil
                                }
                            }
                        }
                    }

                    if !availableAgents.isEmpty {
                        Picker("", selection: $selectedAgentName) {
                            Text("No agent").tag(nil as String?)
                            ForEach(availableAgents) { agent in
                                Text(agent.name).tag(agent.id as String?)
                            }
                        }
                        .frame(width: 120)
                        .font(Typography.monoCaption)
                    }

                    Spacer()
                }
            }

            // Text input
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("New todo for \(project.name)...")
                            .font(Typography.monoBody)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $inputText)
                        .font(Typography.monoBody)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                }
                .frame(height: inputEditorHeight)

                if !inputText.isEmpty {
                    Text("⌘↩")
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 2)
                }
            }
            .onKeyPress(phases: .down) { keyPress in
                if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                    submitTodo()
                    return .handled
                }
                return .ignored
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func submitTodo() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let index = nextAvailableGridIndex()
        let settings = fetchOrCreateSettings()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: text, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        todo.agentName = selectedAgentName

        // Auto-assign teamID: use explicit selection, or find the team containing this agent
        var effectiveTeamID = selectedTeamID
        if effectiveTeamID == nil, let agentName = selectedAgentName {
            effectiveTeamID = projectTeams.first { $0.agentNames.contains(agentName) }?.id
        }
        todo.teamID = effectiveTeamID
        modelContext.insert(todo)

        // Smart engine resolution: agent's parent directory determines harness.
        // .claude/agents/<name>.md → claude engine, .codex/agents/<name>.md → codex engine.
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
