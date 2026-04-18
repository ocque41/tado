import SwiftUI
import SwiftData

/// Per-project detail view. Shows a header with back + new-team,
/// optional inline new-team form, project info + ProjectTodoInput,
/// then a scroll of team sections + unassigned todos + available
/// agents. Mechanical split from the previous monolithic
/// `ProjectsView.projectDetail(_:)` — behavior is identical.
struct ProjectDetailView: View {
    let project: Project
    let onBack: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @State private var showNewTeamInProject: Bool = false
    @State private var newTeamNameInProject: String = ""
    @State private var newTeamAgentsInProject: Set<String> = []
    /// One-at-a-time accordion for team sections. Nil = no team
    /// expanded. Tapping a different team swaps the open one.
    @State private var expandedTeamID: UUID? = nil

    var body: some View {
        let projectTodos = todos.filter { $0.projectID == project.id && $0.listState == .active }
        let projectTeams = teams.filter { $0.projectID == project.id }
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)

        return VStack(spacing: 0) {
            // Header with back button + new team button
            HStack(spacing: 12) {
                Button(action: onBack) {
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
            .background(Palette.surfaceElevated)

            Divider()

            // Inline new team form
            if showNewTeamInProject {
                inlineNewTeamForm(agents: agents)
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

                ProjectTodoInput(project: project)
            }

            Divider()

            // Content: team/agent tree + todo list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !projectTeams.isEmpty {
                        ForEach(projectTeams) { team in
                            teamSection(team, agents: agents, projectTodos: projectTodos)
                        }
                    }

                    let unassigned = projectTodos.filter { $0.teamID == nil }
                    if !unassigned.isEmpty {
                        sectionHeader("Unassigned")
                        ForEach(unassigned) { todo in
                            TodoRowView(todo: todo)
                            Divider().padding(.leading, 60)
                        }
                    }

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

    // MARK: - Team section

    private func teamSection(_ team: Team, agents: [AgentDefinition], projectTodos: [TodoItem]) -> some View {
        let isExpanded = expandedTeamID == team.id
        let names = Array(team.agentNames)

        return VStack(alignment: .leading, spacing: 0) {
            // Team header row — click to expand/collapse, delete button on the right.
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

            // Assigned agents + their todos. Always visible so you can see
            // active work grouped by team even when the row is "collapsed"
            // — the expansion only hides/shows the add-agent chooser.
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

            // When expanded, show available agents as tappable chips to add.
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

    // MARK: - Inline new team form

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
}
