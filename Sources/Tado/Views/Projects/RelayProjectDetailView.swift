// Relay-redesigned per-project detail view.
//
// Replaces ProjectDetailView's legacy DesignKit chrome
// (PageContainer / PageHeader / MetaStrip / SectionRail /
// OutlineButton) with Relay primitives. The inner section contents
// (ProjectDispatchSection / ProjectEternalSection / ProjectTodoInput
// / ProjectTodosSection / ProjectAgentsSection / ProjectKnowledgeView)
// keep their existing implementations — only the wrapping shell
// changes so the visible chrome (kicker / h1 / lead / hairline-
// separated sections + Relay buttons) reads as a Relay surface.

import SwiftUI
import SwiftData

struct RelayProjectDetailView: View {
    let project: Project

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.relayTheme) private var theme
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var newTeamNameInProject: String = ""
    @State private var newTeamAgentsInProject: Set<String> = []
    @State private var expandedTeamID: UUID? = nil
    @State private var inboxExpanded: Bool = true
    @State private var agentsExpanded: Bool = false
    @State private var pathCopiedAt: Date? = nil

    var body: some View {
        @Bindable var appStateBindable = appState

        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return RelayPageContainer {
            relayHead
            metaCard(projectTodos: projectTodos, agents: agents)
            modeToggle(binding: $appStateBindable.projectPageMode)

            // Dispatch
            relaySection(
                kicker: "DISPATCH",
                title: dispatchTitle(),
                trailing: {
                    RelayButton(label: "New plan", variant: .primary) {
                        createDispatchAndEdit()
                    }
                },
                content: {
                    ProjectDispatchSection(project: project)
                        .padding(.vertical, 4)
                }
            )

            // Eternal
            relaySection(
                kicker: "ETERNAL",
                title: eternalTitle(),
                trailing: {
                    HStack(spacing: 8) {
                        RelayButton(label: "New Mega", variant: .standard) {
                            createEternalAndEdit(mode: "mega")
                        }
                        RelayButton(label: "New Sprint", variant: .standard) {
                            createEternalAndEdit(mode: "sprint")
                        }
                    }
                },
                content: {
                    ProjectEternalSection(project: project)
                        .padding(.vertical, 4)
                }
            )

            // Add Todo
            relaySection(
                kicker: "ADD TODO",
                title: "Scoped to /\(project.name).",
                content: {
                    ProjectTodoInput(project: project)
                        .padding(.vertical, 4)
                }
            )

            // Todos
            relaySection(
                kicker: "TODOS",
                title: todosTitle(projectTodos: projectTodos, projectTeams: projectTeams),
                trailing: {
                    RelayButton(label: "New team", variant: .standard) {
                        appState.showNewTeamForActiveProject = true
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
                    .padding(.vertical, 4)
                }
            )

            // Agents
            relaySection(
                kicker: "AGENTS",
                title: "\(agents.count) total — auto-discovered from .claude/agents/ and .codex/agents/.",
                content: {
                    ProjectAgentsSection(
                        project: project,
                        agents: agents,
                        projectTeams: projectTeams,
                        projectTodos: projectTodos,
                        expanded: $agentsExpanded
                    )
                    .padding(.vertical, 4)
                }
            )

            // Knowledge
            relaySection(
                kicker: "KNOWLEDGE",
                title: "Per-project Dome scope.",
                content: {
                    ProjectKnowledgeView(project: project)
                        .padding(.vertical, 4)
                }
            )
        }
        .onDisappear {
            appState.showNewTeamForActiveProject = false
        }
    }

    // MARK: - Head

    private var relayHead: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RelayButton(label: "← Projects", variant: .ghost) {
                        appState.activeProjectID = nil
                    }
                    RelayKicker(text: "PROJECTS — DETAIL")
                }
                Text(project.name)
                    .font(RelayType.h1(size: 60))
                    .tracking(RelayTracking.h1(60))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(project.rootPath)
                        .font(Typography.sans(size: 11, weight: .regular))
                        .tracking(RelayTracking.meta(11))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: copyPath) {
                        Text("COPY")
                            .font(Typography.sans(size: 9, weight: .medium))
                            .tracking(RelayTracking.caps(9))
                            .foregroundStyle(RelayPalette.foreground2(for: theme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: RelayRadius.standard)
                                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    if let pathCopiedAt, Date().timeIntervalSince(pathCopiedAt) < 2 {
                        Text("COPIED")
                            .font(Typography.sans(size: 9, weight: .medium))
                            .tracking(RelayTracking.caps(9))
                            .foregroundStyle(RelayPalette.terracotta)
                    }
                }
            }
            Spacer()
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.rootPath, forType: .string)
        pathCopiedAt = .now
    }

    // MARK: - Meta strip card

    private func metaCard(projectTodos: [TodoItem], agents: [AgentDefinition]) -> some View {
        let activeRuns = project.eternalRuns.filter { $0.state == "running" }.count
            + project.dispatchRuns.filter { $0.state == "dispatching" || $0.state == "planning" }.count
        let isActive = activeRuns > 0
        let stats: [RelayStat] = [
            RelayStat("STATUS", isActive ? "Active" : "Idle",
                      meta: isActive ? "● Live" : nil,
                      metaTint: isActive ? RelayPalette.terracotta : nil),
            RelayStat("RUNS", "\(project.eternalRuns.count + project.dispatchRuns.count)"),
            RelayStat("OPEN", "\(projectTodos.count)"),
            RelayStat("AGENTS", "\(agents.count)"),
        ]
        return RelayStatStrip(stats: stats)
    }

    // MARK: - Mode toggle (Detail | Kanban)

    private func modeToggle(binding: Binding<ProjectPageMode>) -> some View {
        HStack(spacing: 0) {
            RelaySegmented(
                options: [
                    RelaySegmentedOption(label: "Detail", value: ProjectPageMode.detail),
                    RelaySegmentedOption(label: "Kanban", value: ProjectPageMode.kanban),
                ],
                selection: binding
            )
            .frame(width: 220)
            Spacer()
        }
    }

    // MARK: - Section helper

    @ViewBuilder
    private func relaySection<Trailing: View, Content: View>(
        kicker: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        RelaySection(kicker: kicker, title: title, content: content, trailing: trailing)
    }

    // MARK: - Counts / titles

    private func dispatchTitle() -> String {
        let active = project.dispatchRuns.filter {
            ["drafted", "planning", "awaitingReview", "ready", "dispatching"].contains($0.state)
        }.count
        let archived = project.dispatchRuns.filter { $0.state == "completed" }.count
        if active == 0 && archived == 0 { return "No active plans." }
        return "\(active) active · \(archived) archived."
    }

    private func eternalTitle() -> String {
        let active = project.eternalRuns.filter {
            ["drafted", "planning", "awaitingReview", "ready", "running"].contains($0.state)
        }.count
        let archived = project.eternalRuns.filter {
            $0.state == "completed" || $0.state == "stopped"
        }.count
        if active == 0 && archived == 0 { return "No runs." }
        return "\(active) active · \(archived) archived."
    }

    private func todosTitle(projectTodos: [TodoItem], projectTeams: [Team]) -> String {
        let unassigned = projectTodos.filter { $0.teamID == nil }.count
        let inFlight = projectTodos.filter {
            $0.status == .running || $0.status == .needsInput || $0.status == .awaitingResponse
        }.count
        return "\(unassigned) unassigned · \(inFlight) in-flight."
    }

    // MARK: - Mutations (mirror ProjectDetailView)

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
        DomeTeamTopic.writeRoster(project: project, team: team)
        cancelNewTeam()
    }

    private func cancelNewTeam() {
        appState.showNewTeamForActiveProject = false
        newTeamNameInProject = ""
        newTeamAgentsInProject = []
    }
}
