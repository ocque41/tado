import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var showNewProject: Bool = false
    @State private var newProjectName: String = ""
    @State private var newProjectPath: String = ""
    @State private var selectedProjectID: UUID? = nil
    @State private var showNewTeamInProject: Bool = false
    @State private var newTeamNameInProject: String = ""
    @State private var newTeamAgentsInProject: Set<String> = []
    @State private var showPlanNotReadyAlert: Bool = false

    private var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let project = selectedProject {
                projectDetail(project)
            } else {
                projectList
            }
        }
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, click Start again.")
        }
    }

    // MARK: - Project List

    private var projectList: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Projects")
                    .font(Typography.title)

                Spacer()

                Button(action: { showNewProject.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Project")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Palette.surface)

            Divider()

            // New project form
            if showNewProject {
                newProjectForm
                Divider()
            }

            // Project rows
            if projects.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No projects yet")
                        .font(Typography.heading)
                        .foregroundStyle(Palette.textSecondary)
                    Text("Create a project to organize todos by directory")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { project in
                            projectRow(project)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let todoCount = todos.filter { $0.projectID == project.id && $0.listState == .active }.count
        let teamCount = teams.filter { $0.projectID == project.id }.count
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return Button(action: {
            selectedProjectID = project.id
            appState.activeProjectID = project.id
        }) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(Typography.monoDefaultEmph)
                        .foregroundStyle(Palette.textPrimary)
                    Text(project.rootPath)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if agents.count > 0 {
                    Text("\(agents.count) agents")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.surfaceElevated)
                        .clipShape(Capsule())
                }

                if teamCount > 0 {
                    Text("\(teamCount) teams")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.surfaceElevated)
                        .clipShape(Capsule())
                }

                if todoCount > 0 {
                    Text("\(todoCount) todos")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.surfaceAccent)
                        .clipShape(Capsule())
                }

                Button(action: { bootstrapTools(for: project) }) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Bootstrap Tado A2A tools for this project")

                dispatchControls(for: project)

                if teamCount > 0 {
                    Button(action: { bootstrapTeam(for: project) }) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warning.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Bootstrap team awareness for this project")
                }

                Button(action: { deleteProject(project) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.danger.opacity(0.8))
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - New Project Form

    private var newProjectForm: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.plain)
                    .font(Typography.monoBody)
                    .foregroundStyle(Palette.textPrimary)

                Button("Browse...") { pickDirectory() }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
            }

            if !newProjectPath.isEmpty {
                HStack {
                    Text(newProjectPath)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewProject = false
                    newProjectName = ""
                    newProjectPath = ""
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .buttonStyle(.plain)

                Button("Create") { createProject() }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
                    .disabled(newProjectName.isEmpty || newProjectPath.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.surfaceAccentSoft)
    }

    // MARK: - Project Detail

    private func projectDetail(_ project: Project) -> some View {
        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)
        return VStack(spacing: 0) {
            // Header with back button
            HStack(spacing: 12) {
                Button(action: {
                    selectedProjectID = nil
                    appState.activeProjectID = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Projects")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(project.name)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Button(action: { showNewTeamInProject.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Team")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Palette.surface)

            Divider()

            // Inline new team form
            if showNewTeamInProject {
                inlineNewTeamForm(project: project, agents: agents)
                Divider()
            }

            // Project info + todo input
            VStack(spacing: 8) {
                HStack {
                    Text(project.rootPath)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(agents.count) agents")
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Text("\(projectTeams.count) teams")
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                // Todo input for this project
                ProjectTodoInput(project: project)
            }

            Divider()

            // Content: team/agent tree + todo list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Teams section
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

                    // Discovered agents (not in any team)
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
        }
    }

    private func teamSection(_ team: Team, agents: [AgentDefinition], projectTodos: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(team.name)

            let names = Array(team.agentNames)
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
        }
    }

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

    // MARK: - Inline New Team Form

    private func inlineNewTeamForm(project: Project, agents: [AgentDefinition]) -> some View {
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
    }

    // MARK: - Actions

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select project root directory"
        if panel.runModal() == .OK, let url = panel.url {
            newProjectPath = url.path
            if newProjectName.isEmpty {
                newProjectName = url.lastPathComponent
            }
        }
    }

    private func createProject() {
        let project = Project(name: newProjectName, rootPath: newProjectPath)
        modelContext.insert(project)
        try? modelContext.save()
        newProjectName = ""
        newProjectPath = ""
        showNewProject = false
    }

    private func deleteProject(_ project: Project) {
        // Terminate any sessions belonging to this project
        for todo in todos where todo.projectID == project.id {
            terminalManager.terminateSessionForTodo(todo.id)
        }
        modelContext.delete(project)
        try? modelContext.save()
    }

    // MARK: - Dispatch File Controls

    @ViewBuilder
    private func dispatchControls(for project: Project) -> some View {
        let state = project.dispatchState
        if state == "idle" || state.isEmpty {
            Button(action: { appState.dispatchModalProjectID = project.id }) {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text.badge.plus")
                        .font(.system(size: 12))
                    Text("Dispatch")
                        .font(Typography.monoMicro)
                }
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.surfaceAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Write a Dispatch File — a multi-phase super-project plan")
        } else {
            Button(action: { appState.dispatchModalProjectID = project.id }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Palette.warning.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Redo the Dispatch File — edit the brief and re-plan")

            Button(action: { startPhaseOne(for: project) }) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                    Text("Start")
                        .font(Typography.monoMicro)
                }
                .foregroundStyle(Palette.success)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.success.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Start dispatching — launch phase 1 of the plan")
        }
    }

    private func startPhaseOne(for project: Project) {
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

    // MARK: - Bootstrap Tools

    private func bootstrapTools(for project: Project) {
        guard let tadoRoot = ProcessSpawner.tadoRepoRoot() else { return }

        let prompt = ProcessSpawner.bootstrapPrompt(targetPath: project.rootPath)
        let settings = bootstrapFetchOrCreateSettings()
        let index = bootstrapNextAvailableGridIndex()
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

    // MARK: - Bootstrap Team

    private func bootstrapTeam(for project: Project) {
        let projectTeams = teams.filter { $0.projectID == project.id }
        guard !projectTeams.isEmpty else { return }

        let prompt = ProcessSpawner.bootstrapTeamPrompt(
            targetPath: project.rootPath,
            projectName: project.name,
            teams: projectTeams.map { ($0.name, $0.agentNames) }
        )
        let settings = bootstrapFetchOrCreateSettings()
        let index = bootstrapNextAvailableGridIndex()
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

    private func bootstrapNextAvailableGridIndex() -> Int {
        let activeTodos = todos.filter { $0.listState == .active }
        let usedIndices = Set(activeTodos.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }
        return index
    }

    private func bootstrapFetchOrCreateSettings() -> AppSettings {
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

// MARK: - Project-scoped Todo Input

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
