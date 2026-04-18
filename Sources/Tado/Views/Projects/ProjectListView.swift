import SwiftUI
import SwiftData

/// Project list view — header with a single + New button, a stack
/// of `ProjectCard`s, or a centered empty-state CTA when no projects
/// exist. New Project opens as a sheet (see `NewProjectSheet`) so the
/// list never shifts when creation starts.
///
/// Each card calls back via closures for project-tap, dispatch open,
/// bootstrap tools / team, and delete. The ••• menu on the card
/// surfaces the rare actions instead of crowding the row.
struct ProjectListView: View {
    let onSelect: (Project) -> Void

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var showNewProjectSheet: Bool = false
    @State private var showPlanNotReadyAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if projects.isEmpty {
                emptyState
            } else {
                projectCards
            }
        }
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet()
        }
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, try Start again.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Text("Projects")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)

            Spacer()

            Button(action: { showNewProjectSheet = true }) {
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
        .background(Palette.surfaceElevated)
    }

    /// Centered empty-state block. Uses Typography.heading for the line
    /// and body for the subline — matches the visual weight of other
    /// empty states in the app (Settings, Done/Trash). A primary button
    /// carries the same accent treatment as the header button, so a
    /// fresh install has one clear CTA.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No projects yet")
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
            Text("Create one to start organizing your AI coding\nsessions by workspace")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { showNewProjectSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Project")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.surfaceAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var projectCards: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(projects) { project in
                    card(for: project)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }

    private func card(for project: Project) -> some View {
        let todoCount = todos.filter { $0.projectID == project.id && $0.listState == .active }.count
        let teamCount = teams.filter { $0.projectID == project.id }.count
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return ProjectCard(
            project: project,
            todoCount: todoCount,
            teamCount: teamCount,
            agentCount: agents.count,
            hasTeams: teamCount > 0,
            onTap: { onSelect(project) },
            onBootstrapTools: { bootstrapTools(for: project) },
            onBootstrapTeam: { bootstrapTeam(for: project) },
            onDispatch: { appState.dispatchModalProjectID = project.id },
            onStart: { startPhaseOne(for: project) },
            onDelete: { deleteProject(project) }
        )
    }

    // MARK: - Actions

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

    private func deleteProject(_ project: Project) {
        for todo in todos where todo.projectID == project.id {
            terminalManager.terminateSessionForTodo(todo.id)
        }
        modelContext.delete(project)
        try? modelContext.save()
    }

    // MARK: - Bootstrap helpers (same behavior as the pre-redesign row)

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
