import SwiftUI
import SwiftData

/// Per-project detail view. Zone-based layout:
///
/// 1. **Breadcrumb bar** — back link left, ••• menu right (rare
///    actions: bootstrap tools / bootstrap team / new team / delete).
/// 2. **Identity zone** — large project name + path. No controls.
/// 3. **Dispatch section** — the most visually prominent block on
///    the page. See `ProjectDispatchSection` for per-state visuals.
/// 4. **Todo input + todos/agents list** — carried forward from the
///    pre-redesign layout. Step 4 will restructure these into a
///    team > agent > todo disclosure hierarchy; for now they keep
///    their existing shape so this step stays focused on the top
///    half of the page.
struct ProjectDetailView: View {
    let project: Project
    let onBack: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var showNewTeamInProject: Bool = false
    @State private var newTeamNameInProject: String = ""
    @State private var newTeamAgentsInProject: Set<String> = []
    /// One-at-a-time accordion for team sections. Nil = no team
    /// expanded. Tapping a different team swaps the open one.
    @State private var expandedTeamID: UUID? = nil
    @State private var showPlanNotReadyAlert: Bool = false

    var body: some View {
        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return VStack(spacing: 0) {
            breadcrumbBar(projectTeams: projectTeams)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    identityZone

                    ProjectDispatchSection(
                        project: project,
                        onNewDispatch: { appState.dispatchModalProjectID = project.id },
                        onEdit: { appState.dispatchModalProjectID = project.id },
                        onStart: { startPhaseOne() },
                        onWatchOnCanvas: { appState.currentView = .canvas }
                    )

                    // Inline new team form (legacy — will fold into todos zone in Step 4).
                    if showNewTeamInProject {
                        inlineNewTeamForm(agents: agents)
                    }

                    legacyTodosAndAgentsSection(
                        projectTodos: projectTodos,
                        projectTeams: projectTeams,
                        agents: agents
                    )
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, try Start again.")
        }
    }

    // MARK: - Zones

    /// Breadcrumb bar with back on the left and the ••• menu on the right.
    private func breadcrumbBar(projectTeams: [Team]) -> some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Projects")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            actionsMenu(projectTeams: projectTeams)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    /// The "name + path" block. Large identity; no buttons.
    private var identityZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name)
                .font(Typography.titleLg)
                .foregroundStyle(Palette.textPrimary)
            Text(project.rootPath)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The ••• menu in the breadcrumb. Mirrors the list-view card menu
    /// — rare actions live here so the breadcrumb chrome stays minimal.
    private func actionsMenu(projectTeams: [Team]) -> some View {
        Menu {
            Button(action: { showNewTeamInProject.toggle() }) {
                Label("New team…", systemImage: "person.3.sequence")
            }
            Divider()
            Button(action: { bootstrapTools() }) {
                Label("Bootstrap A2A tools", systemImage: "wrench.and.screwdriver")
            }
            Button(action: { bootstrapTeam(projectTeams: projectTeams) }) {
                Label("Bootstrap team awareness", systemImage: "person.3")
            }
            .disabled(projectTeams.isEmpty)
            Divider()
            Button(role: .destructive, action: { deleteProject() }) {
                Label("Delete project", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The pre-redesign todo + teams + agents stack. Step 4 replaces
    /// this with a team > agent > todo disclosure hierarchy. Kept as
    /// a single block so Step 3's diff stays focused on the top half
    /// of the page.
    private func legacyTodosAndAgentsSection(
        projectTodos: [TodoItem],
        projectTeams: [Team],
        agents: [AgentDefinition]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Todo input
            ProjectTodoInput(project: project)
                .padding(.bottom, 4)

            Divider()

            // Team sections
            if !projectTeams.isEmpty {
                ForEach(projectTeams) { team in
                    teamSection(team, agents: agents, projectTodos: projectTodos)
                }
            }

            // Unassigned todos
            let unassigned = projectTodos.filter { $0.teamID == nil }
            if !unassigned.isEmpty {
                sectionHeader("Unassigned")
                ForEach(unassigned) { todo in
                    TodoRowView(todo: todo)
                    Divider().padding(.leading, 60)
                }
            }

            // Available agents not in any team
            let assignedAgents = Set(projectTeams.flatMap(\.agentNames))
            let unassignedAgents = agents.filter { !assignedAgents.contains($0.id) }
            if !unassignedAgents.isEmpty {
                sectionHeader("Available Agents")
                ForEach(unassignedAgents) { agent in
                    agentRow(agent)
                    Divider().padding(.leading, 60)
                }
            }
        }
    }

    // MARK: - Team section (unchanged from Step 1)

    private func teamSection(_ team: Team, agents: [AgentDefinition], projectTodos: [TodoItem]) -> some View {
        let isExpanded = expandedTeamID == team.id
        let names = Array(team.agentNames)

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedTeamID = isExpanded ? nil : team.id
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14)

                    Text(team.name.uppercased())
                        .font(Typography.callout)
                        .tracking(0.6)
                        .foregroundStyle(Palette.textSecondary)

                    Spacer()

                    Text("\(team.agentNames.count) agents")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.surfaceElevated)
                        .clipShape(Capsule())

                    Button(action: { deleteTeam(team) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete team")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Palette.surfaceElevated)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(names, id: \.self) { agentName in
                let agent = agents.first { $0.id == agentName }
                let agentTodos = projectTodos.filter { $0.teamID == team.id && $0.agentName == agentName }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle")
                            .font(.system(size: 12))
                            .foregroundColor(Palette.accent)
                        Text(agent?.name ?? agentName)
                            .font(Typography.monoBodyEmphasis)
                            .foregroundStyle(Palette.textPrimary)
                        if agent == nil {
                            Text("(not found)")
                                .font(Typography.monoMicro)
                                .foregroundStyle(Palette.danger)
                        }
                        Spacer()
                        Text("\(agentTodos.count) todos")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.textSecondary)
                        if isExpanded {
                            Button(action: { removeAgentFromTeam(team, agentName: agentName) }) {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.danger.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Remove agent from team")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)

                    ForEach(agentTodos) { todo in
                        TodoRowView(todo: todo)
                            .padding(.leading, 20)
                        Divider().padding(.leading, 80)
                    }
                }
            }

            if isExpanded {
                let unassigned = agents.filter { !team.agentNames.contains($0.id) }
                if !unassigned.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add:")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.textTertiary)
                        FlowLayout(spacing: 4) {
                            ForEach(unassigned) { agent in
                                Button(action: { addAgentToTeam(team, agentName: agent.id) }) {
                                    Text(agent.name)
                                        .font(Typography.monoMicro)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Palette.surfaceAccent)
                                        .foregroundColor(Palette.accent)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 6)
                    .background(Palette.surfaceAccentSoft)
                }
            }
        }
    }

    // MARK: - Inline new team form (unchanged — will fold into todos zone in Step 4)

    private func inlineNewTeamForm(agents: [AgentDefinition]) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Team name", text: $newTeamNameInProject)
                    .textFieldStyle(.plain)
                    .font(Typography.monoBody)
                    .foregroundStyle(Palette.textPrimary)
            }

            if !agents.isEmpty {
                HStack(spacing: 8) {
                    Text("Agents:")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(agents) { agent in
                        let isSelected = newTeamAgentsInProject.contains(agent.id)
                        Button(action: {
                            if isSelected { newTeamAgentsInProject.remove(agent.id) }
                            else { newTeamAgentsInProject.insert(agent.id) }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10))
                                Text(agent.name)
                                    .font(Typography.monoCaption)
                            }
                            .foregroundColor(isSelected ? Palette.accent : Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewTeamInProject = false
                    newTeamNameInProject = ""
                    newTeamAgentsInProject = []
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .buttonStyle(.plain)

                Button("Create") {
                    let team = Team(name: newTeamNameInProject, projectID: project.id, agentNames: Array(newTeamAgentsInProject))
                    modelContext.insert(team)
                    try? modelContext.save()
                    showNewTeamInProject = false
                    newTeamNameInProject = ""
                    newTeamAgentsInProject = []
                }
                .font(Typography.label)
                .foregroundStyle(Palette.accent)
                .buttonStyle(.plain)
                .disabled(newTeamNameInProject.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.surfaceAccentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.callout)
            .tracking(0.6)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceElevated)
    }

    private func agentRow(_ agent: AgentDefinition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            Text(agent.name)
                .font(Typography.monoBody)
                .foregroundStyle(Palette.textPrimary)
            Text("(\(agent.source.rawValue))")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: - Team mutations

    private func deleteTeam(_ team: Team) {
        if expandedTeamID == team.id {
            expandedTeamID = nil
        }
        modelContext.delete(team)
        try? modelContext.save()
    }

    private func addAgentToTeam(_ team: Team, agentName: String) {
        guard !team.agentNames.contains(agentName) else { return }
        team.agentNames.append(agentName)
        try? modelContext.save()
    }

    private func removeAgentFromTeam(_ team: Team, agentName: String) {
        team.agentNames.removeAll { $0 == agentName }
        try? modelContext.save()
    }

    // MARK: - Project actions

    private func startPhaseOne() {
        let launched = DispatchPlanService.startPhaseOne(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        if !launched {
            showPlanNotReadyAlert = true
        }
    }

    private func deleteProject() {
        for todo in todos where todo.projectID == project.id {
            terminalManager.terminateSessionForTodo(todo.id)
        }
        modelContext.delete(project)
        try? modelContext.save()
        onBack()
    }

    private func bootstrapTools() {
        guard let tadoRoot = ProcessSpawner.tadoRepoRoot() else { return }

        let prompt = ProcessSpawner.bootstrapPrompt(targetPath: project.rootPath)
        let settings = fetchOrCreateSettings()
        let index = nextAvailableGridIndex()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: tadoRoot,
            projectName: "Tado"
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    private func bootstrapTeam(projectTeams: [Team]) {
        guard !projectTeams.isEmpty else { return }

        let prompt = ProcessSpawner.bootstrapTeamPrompt(
            targetPath: project.rootPath,
            projectName: project.name,
            teams: projectTeams.map { ($0.name, $0.agentNames) }
        )
        let settings = fetchOrCreateSettings()
        let index = nextAvailableGridIndex()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    private func nextAvailableGridIndex() -> Int {
        let activeTodos = todos.filter { $0.listState == .active }
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
