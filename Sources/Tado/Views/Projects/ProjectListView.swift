import SwiftUI
import SwiftData

/// Project list view — body is a stack of `ProjectCard`s, or a
/// centered empty-state CTA when no projects exist. The page header
/// (title + "+ New Project" button) lives in `TopNavBar` now, so this
/// view contributes only the scrollable list itself. New Project still
/// opens as a sheet — `TopNavBar` flips `appState.showNewProjectSheet`
/// and `ContentView` presents `NewProjectSheet` from there.
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
    @State private var showPlanNotReadyAlert: Bool = false

    var body: some View {
        Group {
            if projects.isEmpty {
                emptyState
            } else {
                projectCards
            }
        }
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, try Start again.")
        }
    }

    // MARK: - Pieces

    /// Centered empty-state block. Uses Typography.heading for the line
    /// and body for the subline — matches the visual weight of other
    /// empty states in the app (Settings, Done/Trash). The primary CTA
    /// flips the same `appState.showNewProjectSheet` flag the nav bar
    /// uses, so a fresh install still has one obvious call to action.
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
            Button(action: { appState.showNewProjectSheet = true }) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            onBootstrapAutoMode: { bootstrapAutoMode(for: project) },
            onBootstrapKnowledge: { bootstrapKnowledge(for: project) },
            onDispatch: { createDispatchRunAndEdit(for: project) },
            onStart: { startMostRecentPhaseOne(for: project) },
            onDelete: { deleteProject(project) }
        )
    }

    // MARK: - Actions

    /// Create a fresh DispatchRun in drafted state and open its brief editor.
    /// The list card's "New Dispatch" shortcut no longer short-circuits to the
    /// modal on the project's single dispatch — each click is a new run.
    private func createDispatchRunAndEdit(for project: Project) {
        let run = DispatchRun(
            project: project,
            label: DispatchRun.defaultLabel(),
            state: "drafted",
            brief: ""
        )
        modelContext.insert(run)
        try? modelContext.save()
        appState.dispatchModalRunID = run.id
    }

    /// Start phase 1 of the project's most-recently-created "ready" dispatch.
    /// Used by the list card's Start shortcut. If none, alert.
    private func startMostRecentPhaseOne(for project: Project) {
        let ready = project.dispatchRuns
            .filter { DispatchPlanService.planExistsOnDisk($0) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        guard let run = ready else {
            showPlanNotReadyAlert = true
            return
        }
        let launched = DispatchPlanService.startPhaseOne(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        if !launched {
            showPlanNotReadyAlert = true
        }
    }

    private func deleteProject(_ project: Project) {
        ProjectActionsService.deleteProject(
            project,
            modelContext: modelContext,
            terminalManager: terminalManager
        )
    }

    private func bootstrapTools(for project: Project) {
        ProjectActionsService.bootstrapTools(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }

    private func bootstrapTeam(for project: Project) {
        let projectTeams = teams.filter { $0.projectID == project.id }
        ProjectActionsService.bootstrapTeam(
            project: project,
            teams: projectTeams,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }

    private func bootstrapAutoMode(for project: Project) {
        ProjectActionsService.bootstrapAutoMode(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }

    private func bootstrapKnowledge(for project: Project) {
        ProjectActionsService.bootstrapKnowledge(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }
}
