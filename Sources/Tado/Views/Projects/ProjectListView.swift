import SwiftUI
import SwiftData

/// Project list view — header + optional new-project form + project
/// rows (or empty state). Each row exposes dispatch controls,
/// bootstrap tools, bootstrap team, and delete actions, plus taps
/// the whole row to open the project via `onSelect`.
struct ProjectListView: View {
    let onSelect: (Project) -> Void

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var showNewProject: Bool = false
    @State private var newProjectName: String = ""
    @State private var newProjectPath: String = ""
    @State private var showPlanNotReadyAlert: Bool = false

    var body: some View {
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
            .background(Palette.surfaceElevated)

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
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, click Start again.")
        }
    }

    // MARK: - Project row

    private func projectRow(_ project: Project) -> some View {
        let todoCount = todos.filter { $0.projectID == project.id && $0.listState == .active }.count
        let teamCount = teams.filter { $0.projectID == project.id }.count
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return Button(action: {
            onSelect(project)
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

    // MARK: - New project form

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
        for todo in todos where todo.projectID == project.id {
            terminalManager.terminateSessionForTodo(todo.id)
        }
        modelContext.delete(project)
        try? modelContext.save()
    }

    // MARK: - Dispatch controls

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

    // MARK: - Bootstrap helpers

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
