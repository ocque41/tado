import SwiftUI
import SwiftData

struct TeamsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @State private var showNewTeam: Bool = false
    @State private var newTeamName: String = ""
    @State private var newTeamProjectID: UUID? = nil
    @State private var newTeamAgents: Set<String> = []
    @State private var expandedTeamID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Teams")
                    .font(Typography.title)

                Spacer()

                Button(action: { showNewTeam.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Team")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(projects.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Palette.surfaceElevated)

            Divider()

            // New team form
            if showNewTeam {
                newTeamForm
                Divider()
            }

            // Teams grouped by project
            if teams.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No teams yet")
                        .font(Typography.heading)
                        .foregroundStyle(Palette.textSecondary)
                    if projects.isEmpty {
                        Text("Create a project first, then add teams")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        Text("Create a team to organize agents")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { project in
                            let projectTeams = teams.filter { $0.projectID == project.id }
                            if !projectTeams.isEmpty {
                                projectSection(project, teams: projectTeams)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
    }

    // MARK: - Project Section

    private func projectSection(_ project: Project, teams: [Team]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.accent)
                Text(project.name.uppercased())
                    .font(Typography.callout)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Palette.surfaceElevated)

            ForEach(teams) { team in
                teamRow(team, project: project)
                Divider().padding(.leading, 44)
            }
        }
    }

    private func teamRow(_ team: Team, project: Project) -> some View {
        let agents = AgentDiscoveryService.discover(projectRoot: project.rootPath)
        let todoCount = todos.filter { $0.teamID == team.id && $0.listState == .active }.count
        let isExpanded = expandedTeamID == team.id

        return VStack(alignment: .leading, spacing: 0) {
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

                    Image(systemName: "person.3")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.accent)

                    Text(team.name)
                        .font(Typography.monoDefaultEmph)
                        .foregroundStyle(Palette.textPrimary)

                    Spacer()

                    Text("\(team.agentNames.count) agents")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.surfaceElevated)
                        .clipShape(Capsule())

                    if todoCount > 0 {
                        Text("\(todoCount) todos")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.surfaceAccent)
                            .clipShape(Capsule())
                    }

                    Button(action: { deleteTeam(team) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: show agents with add/remove
            if isExpanded {
                expandedTeamContent(team, allAgents: agents)
            }
        }
    }

    private func expandedTeamContent(_ team: Team, allAgents: [AgentDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Assigned agents
            let assignedNames = Array(team.agentNames)
            ForEach(assignedNames, id: \.self) { agentName in
                let agent = allAgents.first { $0.id == agentName }
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.accent)
                    Text(agent?.name ?? agentName)
                        .font(Typography.monoRow)
                        .foregroundStyle(Palette.textPrimary)
                    if let agent = agent {
                        Text("(\(agent.source.rawValue))")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    if agent == nil {
                        Text("(not found on disk)")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.danger)
                    }
                    Spacer()
                    Button(action: { removeAgentFromTeam(team, agentName: agentName) }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 4)
            }

            // Available agents to add
            let unassigned = allAgents.filter { !team.agentNames.contains($0.id) }
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
            }
        }
        .padding(.bottom, 4)
        .background(Palette.surfaceAccentSoft)
    }

    // MARK: - New Team Form

    private var newTeamForm: some View {
        let selectedProject = projects.first { $0.id == newTeamProjectID }
        let agents: [AgentDefinition] = selectedProject.map { AgentDiscoveryService.discover(projectRoot: $0.rootPath) } ?? []

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Team name", text: $newTeamName)
                    .textFieldStyle(.plain)
                    .font(Typography.monoBody)
                    .foregroundStyle(Palette.textPrimary)

                Picker("Project", selection: $newTeamProjectID) {
                    Text("Select project...").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .frame(width: 160)
                .font(Typography.monoCaption)
            }

            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents:")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    FlowLayout(spacing: 4) {
                        ForEach(agents) { agent in
                            agentToggleButton(agent)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewTeam = false
                    resetNewTeamForm()
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .buttonStyle(.plain)

                Button("Create") { createTeam() }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
                    .disabled(newTeamName.isEmpty || newTeamProjectID == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.surfaceAccentSoft)
    }

    private func agentToggleButton(_ agent: AgentDefinition) -> some View {
        let isSelected = newTeamAgents.contains(agent.id)
        return Button(action: {
            if isSelected {
                newTeamAgents.remove(agent.id)
            } else {
                newTeamAgents.insert(agent.id)
            }
        }) {
            Text(agent.name)
                .font(Typography.monoMicro)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Palette.surfaceAccent : Palette.surfaceElevated)
                .foregroundColor(isSelected ? Palette.accent : Palette.textSecondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func createTeam() {
        guard let projectID = newTeamProjectID else { return }
        let team = Team(name: newTeamName, projectID: projectID, agentNames: Array(newTeamAgents))
        modelContext.insert(team)
        try? modelContext.save()
        showNewTeam = false
        resetNewTeamForm()
    }

    private func resetNewTeamForm() {
        newTeamName = ""
        newTeamProjectID = nil
        newTeamAgents = []
    }

    private func deleteTeam(_ team: Team) {
        modelContext.delete(team)
        try? modelContext.save()
    }

    private func addAgentToTeam(_ team: Team, agentName: String) {
        team.agentNames.append(agentName)
        try? modelContext.save()
    }

    private func removeAgentFromTeam(_ team: Team, agentName: String) {
        team.agentNames.removeAll { $0 == agentName }
        try? modelContext.save()
    }
}
