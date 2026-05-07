import SwiftUI
import SwiftData

/// Per-project detail view, redesigned in v0.18 to follow the
/// "Projects Page" structural-grid mockup:
///
/// 1. **`PageHeader`** — project name, copyable rootPath, and a
///    `MetaStrip` of `Status / Runs / Open todos / Agents / Last
///    update` cells on the right.
/// 2. **Dispatch section** (`SectionRail` "DISPATCH") — empty-state
///    block with ASCII art + tagline when no plans exist; otherwise
///    a runs table (delegated to `ProjectDispatchSection`).
/// 3. **Eternal section** (`SectionRail` "ETERNAL") — "New Mega" /
///    "New Sprint" buttons in the rail, runs table on the right
///    with archived disclosure.
/// 4. **Add Todo section** (`SectionRail` "ADD TODO") — composer
///    card with the editor + `⌘⏎` footer.
/// 5. **Todos section** (`SectionRail` "TODOS") — INBOX + per-team
///    disclosures, each rendering an indexed todo table.
/// 6. **Agents section** (`SectionRail` "AGENTS") — collapsible
///    roster with source pills and team membership.
///
/// The page is wrapped in `PageContainer` so the gutters, max width,
/// and bottom safe-area match every other page that adopts the new
/// design.
struct ProjectDetailView: View {
    let project: Project

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var newTeamNameInProject: String = ""
    @State private var newTeamAgentsInProject: Set<String> = []
    @State private var expandedTeamID: UUID? = nil
    @State private var inboxExpanded: Bool = true
    @State private var agentsExpanded: Bool = false
    /// Briefly flashes "Copied" under the path when the user hits the
    /// copy glyph in the page header.
    @State private var pathCopiedAt: Date? = nil

    var body: some View {
        @Bindable var appStateBindable = appState

        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return PageContainer {
            PageHeader(
                title: project.name,
                path: project.rootPath,
                pathOnCopy: { pathCopiedAt = .now }
            ) {
                metaStrip(projectTodos: projectTodos, agents: agents)
            }

            // Page-mode toggle (Detail | Kanban). Sits below the
            // header so the user can flip to the per-project Kanban
            // board without leaving the project context. The same
            // picker lives at the top of `ProjectKanbanView` for the
            // return trip. Uses the design-system `ModeTab` primitive
            // so every "view mode" toggle in the app reads the same.
            HStack(spacing: 10) {
                ModeTab(
                    eyebrow: "VIEW",
                    options: [
                        .init(id: ProjectPageMode.detail, label: "Detail", icon: "list.bullet.rectangle"),
                        .init(id: ProjectPageMode.kanban, label: "Kanban", icon: "rectangle.split.3x1"),
                    ],
                    selection: $appStateBindable.projectPageMode
                )
                Spacer()
            }
            .padding(.bottom, 12)

            // Dispatch
            SectionRail(
                label: "Dispatch",
                count: dispatchCount(),
                actions: {
                    OutlineButton("New plan", icon: "plus", size: .small, variant: .accent) {
                        createDispatchAndEdit()
                    }
                },
                content: {
                    ProjectDispatchSection(project: project)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            )

            // Eternal
            SectionRail(
                label: "Eternal",
                count: eternalCount(),
                actions: {
                    VStack(alignment: .leading, spacing: 6) {
                        OutlineButton("New Mega", icon: "infinity", size: .small) {
                            createEternalAndEdit(mode: "mega")
                        }
                        OutlineButton("New Sprint", icon: "repeat", size: .small) {
                            createEternalAndEdit(mode: "sprint")
                        }
                    }
                },
                content: {
                    ProjectEternalSection(project: project)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            )

            // Add Todo
            SectionRail(
                label: "Add Todo",
                count: "scoped · /\(project.name)"
            ) {
                ProjectTodoInput(project: project)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
            }

            // Todos
            SectionRail(
                label: "Todos",
                count: todosCount(projectTodos: projectTodos, projectTeams: projectTeams),
                actions: {
                    VStack(alignment: .leading, spacing: 6) {
                        OutlineButton("New team", icon: "person.3.sequence", size: .small) {
                            appState.showNewTeamForActiveProject = true
                        }
                    }
                },
                content: {
                    ProjectTodosSection(
                        project: project,
                        projectTodos: projectTodos,
                        projectTeams: projectTeams,
                        agents: agents,
                        expandedTeamID: $expandedTeamID,
                        inboxExpanded: $inboxExpanded,
                        showNewTeamInProject: $appStateBindable.showNewTeamForActiveProject,
                        newTeamNameInProject: $newTeamNameInProject,
                        newTeamAgentsInProject: $newTeamAgentsInProject,
                        onDeleteTeam: { deleteTeam($0) },
                        onAddAgent: { team, name in addAgentToTeam(team, agentName: name) },
                        onRemoveAgent: { team, name in removeAgentFromTeam(team, agentName: name) },
                        onCommitNewTeam: { commitNewTeam() },
                        onCancelNewTeam: { cancelNewTeam() }
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            )

            // Agents
            SectionRail(
                label: "Agents",
                count: "\(agents.count) total"
            ) {
                ProjectAgentsSection(
                    project: project,
                    agents: agents,
                    projectTeams: projectTeams,
                    projectTodos: projectTodos,
                    expanded: $agentsExpanded
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            // Knowledge — per-project Dome management. New in v1.1:
            // codebase ingest, vector bootstrap, recipes, scope-
            // isolation toggle, and per-project resets so projects
            // stop colliding in the global Dome vault.
            SectionRail(
                label: "Knowledge",
                count: "scoped · /\(project.name)",
                bottomDivider: false
            ) {
                ProjectKnowledgeView(project: project)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .onDisappear {
            // Reset "new team" affordance when leaving so reopening
            // any project starts collapsed.
            appState.showNewTeamForActiveProject = false
        }
    }

    // MARK: - PageHeader meta strip

    private func metaStrip(projectTodos: [TodoItem], agents: [AgentDefinition]) -> some View {
        let activeRuns = project.eternalRuns.filter { $0.state == "running" }.count
            + project.dispatchRuns.filter { $0.state == "dispatching" || $0.state == "planning" }.count
        let isActive = activeRuns > 0
        let lastUpdate = lastUpdateString()

        return MetaStrip {
            MetaCell(
                key: "Status",
                value: isActive ? "● Active" : "○ Idle",
                tint: isActive ? Palette.green : Palette.ink3
            )
            MetaCell(key: "Runs", value: "\(project.eternalRuns.count + project.dispatchRuns.count)")
            MetaCell(key: "Open todos", value: "\(projectTodos.count)")
            MetaCell(key: "Agents", value: "\(agents.count)")
            MetaCell(key: "Last update", value: lastUpdate, trailingDivider: false)
        }
    }

    /// Newest signal across todos + runs, formatted in the design's
    /// short relative form ("2m ago" / "4h ago" / "—").
    private func lastUpdateString() -> String {
        var dates: [Date] = []
        dates.append(project.createdAt)
        dates.append(contentsOf: project.eternalRuns.map(\.createdAt))
        dates.append(contentsOf: project.dispatchRuns.map(\.createdAt))
        let projectTodos = todos.filter { $0.projectID == project.id }
        dates.append(contentsOf: projectTodos.map(\.createdAt))
        guard let latest = dates.max() else { return "—" }
        let secs = max(0, Int(Date().timeIntervalSince(latest)))
        switch secs {
        case 0..<60:        return "just now"
        case 60..<3600:     return "\(secs / 60)m ago"
        case 3600..<86_400: return "\(secs / 3600)h ago"
        default:            return "\(secs / 86_400)d ago"
        }
    }

    // MARK: - Section counts

    private func dispatchCount() -> String {
        let active = project.dispatchRuns.filter {
            ["drafted", "planning", "awaitingReview", "ready", "dispatching"].contains($0.state)
        }.count
        let archived = project.dispatchRuns.filter { $0.state == "completed" }.count
        if active == 0 && archived == 0 { return "No active plans" }
        return "\(active) active · \(archived) archived"
    }

    private func eternalCount() -> String {
        let active = project.eternalRuns.filter {
            ["drafted", "planning", "awaitingReview", "ready", "running"].contains($0.state)
        }.count
        let archived = project.eternalRuns.filter {
            $0.state == "completed" || $0.state == "stopped"
        }.count
        if active == 0 && archived == 0 { return "No runs" }
        return "\(active) active · \(archived) archived"
    }

    private func todosCount(projectTodos: [TodoItem], projectTeams: [Team]) -> String {
        let unassigned = projectTodos.filter { $0.teamID == nil }.count
        let inFlight = projectTodos.filter {
            $0.status == .running || $0.status == .needsInput || $0.status == .awaitingResponse
        }.count
        return "\(unassigned) unassigned · \(inFlight) in-flight"
    }

    // MARK: - Mutations

    private func createDispatchAndEdit() {
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

    private func createEternalAndEdit(mode: String) {
        let run = EternalRun(
            project: project,
            label: EternalRun.defaultLabel(mode: mode),
            state: "drafted",
            mode: mode,
            userBrief: ""
        )
        modelContext.insert(run)
        try? modelContext.save()
        appState.eternalModalRunID = run.id
    }

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

        // C3: write the team roster to the project's Dome topic so
        // agents spawned into any team in this project can query
        // `dome_search --topic project-<id>` for membership context.
        DomeTeamTopic.writeRoster(project: project, team: team)

        cancelNewTeam()
    }

    private func cancelNewTeam() {
        appState.showNewTeamForActiveProject = false
        newTeamNameInProject = ""
        newTeamAgentsInProject = []
    }
}
