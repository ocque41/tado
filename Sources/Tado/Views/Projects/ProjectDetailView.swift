import SwiftUI
import SwiftData

/// Per-project detail view. Zone-based layout:
///
/// 1. **Identity zone** — large project name + path. (Back navigation
///    + the per-project actions menu live in `TopNavBar`; this view
///    no longer renders its own breadcrumb bar.)
/// 2. **Dispatch section** — the most visually prominent block on the
///    page. See `ProjectDispatchSection` for per-state visuals.
/// 3. **Add todo** — card wrapping `ProjectTodoInput`.
/// 4. **Todos section** — `ProjectTodosSection` with INBOX + team
///    disclosures (team > agent > todo hierarchy). The inline new-team
///    form is gated by `appState.showNewTeamForActiveProject` so the
///    nav bar's "New team…" item can pop the form open.
/// 5. **Agents section** — `ProjectAgentsSection` lists discovered
///    agent definitions for the project root.
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

    var body: some View {
        @Bindable var appStateBindable = appState

        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                identityZone

                ProjectDispatchSection(project: project)

                ProjectEternalSection(project: project)

                addTodoZone

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
        .onDisappear {
            // The new-team flag is global on AppState — clear it when the
            // page goes away so reopening any project starts collapsed.
            appState.showNewTeamForActiveProject = false
        }
    }

    // MARK: - Zones

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
