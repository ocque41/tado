import SwiftUI
import SwiftData

/// Per-project detail view. Zone-based layout:
///
/// 1. **Breadcrumb bar** — back link + ••• menu (new team / bootstrap
///    A2A tools / bootstrap team / delete project).
/// 2. **Identity zone** — large project name + path.
/// 3. **Dispatch section** — the most visually prominent block on the
///    page. See `ProjectDispatchSection` for per-state visuals.
/// 4. **Add todo** — card wrapping `ProjectTodoInput`.
/// 5. **Todos section** — `ProjectTodosSection` with INBOX + team
///    disclosures (team > agent > todo hierarchy).
///
/// Step 5 adds the Agents disclosure zone below; Step 6 polishes.
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
    @State private var expandedTeamID: UUID? = nil
    @State private var inboxExpanded: Bool = true
    @State private var agentsExpanded: Bool = false
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

                    addTodoZone

                    ProjectTodosSection(
                        project: project,
                        projectTodos: projectTodos,
                        projectTeams: projectTeams,
                        agents: agents,
                        expandedTeamID: $expandedTeamID,
                        inboxExpanded: $inboxExpanded,
                        showNewTeamInProject: $showNewTeamInProject,
                        newTeamNameInProject: $newTeamNameInProject,
                        newTeamAgentsInProject: $newTeamAgentsInProject,
                        onDeleteTeam: { deleteTeam($0) },
                        onAddAgent: { team, name in addAgentToTeam(team, agentName: name) },
                        onRemoveAgent: { team, name in removeAgentFromTeam(team, agentName: name) },
                        onCommitNewTeam: { commitNewTeam() },
                        onCancelNewTeam: { cancelNewTeam() }
                    )

                    ProjectAgentsSection(
                        project: project,
                        agents: agents,
                        projectTeams: projectTeams,
                        projectTodos: projectTodos,
                        expanded: $agentsExpanded
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

    private var addTodoZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD TODO")
                .font(Typography.callout)
                .tracking(0.6)
                .foregroundStyle(Palette.textSecondary)
            ProjectTodoInput(project: project)
        }
    }

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

    private func commitNewTeam() {
        let trimmed = newTeamNameInProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let team = Team(name: trimmed, projectID: project.id, agentNames: Array(newTeamAgentsInProject))
        modelContext.insert(team)
        try? modelContext.save()
        cancelNewTeam()
    }

    private func cancelNewTeam() {
        showNewTeamInProject = false
        newTeamNameInProject = ""
        newTeamAgentsInProject = []
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
