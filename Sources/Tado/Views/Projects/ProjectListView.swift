import SwiftUI
import SwiftData

/// Project list view, redesigned in v0.18 to match the structural-grid
/// design system: a `PageHeader` with a "Projects" title + `MetaStrip`
/// (totals across the index) and one `SectionRail` ("Projects")
/// hosting either the empty-state CTA or the cards list.
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
        PageContainer {
            PageHeader(title: "Projects") {
                metaStrip
            }

            SectionRail(
                label: "Projects",
                count: projectsCount,
                actions: {
                    OutlineButton("New Project", icon: "plus", size: .small, variant: .accent) {
                        appState.showNewProjectSheet = true
                    }
                },
                content: {
                    if projects.isEmpty {
                        emptyState
                    } else {
                        cardsList
                    }
                },
                bottomDivider: false
            )
        }
        .alert("Architect still planning", isPresented: $showPlanNotReadyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Dispatch Architect has not finished writing the plan yet. Watch its terminal on the canvas — once plan.json is on disk, try Start again.")
        }
    }

    // MARK: - Page meta

    private var metaStrip: some View {
        let totalActiveTodos = todos.filter { $0.listState == .active }.count
        let totalTeams = teams.count
        let totalEternalRunning = projects.flatMap(\.eternalRuns).filter { $0.state == "running" }.count
        let totalDispatching = projects.flatMap(\.dispatchRuns).filter { $0.state == "dispatching" || $0.state == "planning" }.count

        return MetaStrip {
            MetaCell(
                key: "Status",
                value: (totalEternalRunning + totalDispatching) > 0 ? "● Active" : "○ Idle",
                tint: (totalEternalRunning + totalDispatching) > 0 ? Palette.green : Palette.ink3
            )
            MetaCell(key: "Projects", value: "\(projects.count)")
            MetaCell(key: "Open todos", value: "\(totalActiveTodos)")
            MetaCell(key: "Teams", value: "\(totalTeams)")
            MetaCell(key: "Live runs", value: "\(totalEternalRunning + totalDispatching)", trailingDivider: false)
        }
    }

    private var projectsCount: String {
        switch projects.count {
        case 0: return "No projects yet"
        case 1: return "1 project"
        default: return "\(projects.count) projects"
        }
    }

    // MARK: - Cards / empty state

    private var cardsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(projects.enumerated()), id: \.element.id) { idx, project in
                card(for: project)
                if idx < projects.count - 1 {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: DK.ruleW)
                }
            }
        }
    }

    /// Empty-state slot fills the section content area with a left-
    /// aligned heading + subline + outline CTA, matching the design's
    /// "no plans" / "no agents" pattern (left-aligned, mono help line).
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No projects yet")
                .font(Font.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Create one to start organizing your AI coding sessions by workspace.")
                .font(Font.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            OutlineButton("New Project", icon: "plus", size: .small, variant: .accent) {
                appState.showNewProjectSheet = true
            }
            Text("PROJECT REGISTRY  ·  one rootPath per project  ·  agents auto-discovered from .claude/agents and .codex/agents")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: 1)
                        .padding(.horizontal, -2)
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            onBootstrapCoworkPlugin: { bootstrapCoworkPlugin(for: project) },
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

    private func bootstrapCoworkPlugin(for project: Project) {
        ProjectActionsService.bootstrapCoworkPlugin(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }
}
