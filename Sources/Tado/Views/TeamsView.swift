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
                    .font(.system(size: 12, design: .monospaced))
                }
                .buttonStyle(.plain)
                .disabled(projects.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

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
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if projects.isEmpty {
                        Text("Create a project first, then add teams")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Create a team to organize agents")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
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
    }

    // MARK: - Project Section

    private func projectSection(_ project: Project, teams: [Team]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(project.name.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))

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
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)

                    Image(systemName: "person.3")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)

                    Text(team.name)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))

                    Spacer()

                    Text("\(team.agentNames.count) agents")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())

                    if todoCount > 0 {
                        Text("\(todoCount) todos")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Button(action: { deleteTeam(team) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
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
                        .foregroundColor(.accentColor)
                    Text(agent?.name ?? agentName)
                        .font(.system(size: 12, design: .monospaced))
                    if let agent = agent {
                        Text("(\(agent.source.rawValue))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if agent == nil {
                        Text("(not found on disk)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button(action: { removeAgentFromTeam(team, agentName: agentName) }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
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
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4) {
                        ForEach(unassigned) { agent in
                            Button(action: { addAgentToTeam(team, agentName: agent.id) }) {
                                Text(agent.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.1))
                                    .foregroundColor(.accentColor)
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
        .background(Color.accentColor.opacity(0.02))
    }

    // MARK: - New Team Form

    private var newTeamForm: some View {
        let selectedProject = projects.first { $0.id == newTeamProjectID }
        let agents: [AgentDefinition] = selectedProject.map { AgentDiscoveryService.discover(projectRoot: $0.rootPath) } ?? []

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Team name", text: $newTeamName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))

                Picker("Project", selection: $newTeamProjectID) {
                    Text("Select project...").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .frame(width: 160)
                .font(.system(size: 11, design: .monospaced))
            }

            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
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
                .font(.system(size: 12, design: .monospaced))
                .buttonStyle(.plain)

                Button("Create") { createTeam() }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .buttonStyle(.plain)
                    .disabled(newTeamName.isEmpty || newTeamProjectID == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.04))
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
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
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
