import SwiftUI
import SwiftData

/// The "TODOS" zone of the detail view. Renders:
///
/// - **INBOX** — collapsible disclosure for unassigned todos (those
///   with `teamID == nil`). Only visible when there are unassigned
///   items. Collapsed by default, with a subtle unassigned-count
///   subline.
/// - One **`ProjectTeamDisclosure`** per team, in team creation order.
///   Each team is expandable with agent → todo nesting inside.
/// - An optional inline **new-team form** — shown when the user picks
///   "New team…" from the detail view's breadcrumb menu.
///
/// Also renders an empty-state line if the project has no todos at
/// all and no teams — so a fresh project doesn't display an empty
/// "TODOS" header with nothing underneath.
struct ProjectTodosSection: View {
    let project: Project
    let projectTodos: [TodoItem]
    let projectTeams: [Team]
    let agents: [AgentDefinition]
    @Binding var expandedTeamID: UUID?
    @Binding var inboxExpanded: Bool
    @Binding var showNewTeamInProject: Bool
    @Binding var newTeamNameInProject: String
    @Binding var newTeamAgentsInProject: Set<String>
    let onDeleteTeam: (Team) -> Void
    let onAddAgent: (Team, String) -> Void
    let onRemoveAgent: (Team, String) -> Void
    let onCommitNewTeam: () -> Void
    let onCancelNewTeam: () -> Void

    private var unassignedTodos: [TodoItem] {
        projectTodos.filter { $0.teamID == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODOS")
                .font(Typography.callout)
                .tracking(0.6)
                .foregroundStyle(Palette.textSecondary)

            if showNewTeamInProject {
                newTeamForm
            }

            if projectTeams.isEmpty && projectTodos.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !unassignedTodos.isEmpty {
                        inboxDisclosure
                    }
                    ForEach(projectTeams) { team in
                        ProjectTeamDisclosure(
                            team: team,
                            agents: agents,
                            projectTodos: projectTodos,
                            expandedTeamID: $expandedTeamID,
                            onDelete: { onDeleteTeam(team) },
                            onRemoveAgent: { name in onRemoveAgent(team, name) },
                            onAddAgent: { name in onAddAgent(team, name) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Inbox

    /// Matches the visual rhythm of the team disclosures but always
    /// stays neutral (no ••• menu, no accent on the label) so it
    /// reads as a system-level bucket rather than a user-owned team.
    private var inboxDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    inboxExpanded.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: inboxExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14)

                    Text("INBOX")
                        .font(Typography.callout)
                        .tracking(0.6)
                        .foregroundStyle(Palette.textPrimary)

                    Spacer()

                    Text("\(unassignedTodos.count) \(unassignedTodos.count == 1 ? "unassigned" : "unassigned")")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if inboxExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unassignedTodos) { todo in
                        TodoRowView(todo: todo)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text("No todos yet. Type one into the ADD TODO card above, or use ••• → New team to organize agents first.")
            .font(Typography.body)
            .foregroundStyle(Palette.textTertiary)
            .padding(.vertical, 12)
    }

    // MARK: - Inline new-team form

    private var newTeamForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW TEAM")
                .font(Typography.microBold)
                .tracking(0.6)
                .foregroundStyle(Palette.textSecondary)

            TextField("", text: $newTeamNameInProject,
                      prompt: Text("Team name").foregroundStyle(Palette.textTertiary))
                .textFieldStyle(.plain)
                .font(Typography.monoBody)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Palette.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(agents) { agent in
                            let isSelected = newTeamAgentsInProject.contains(agent.id)
                            Button(action: {
                                if isSelected { newTeamAgentsInProject.remove(agent.id) }
                                else { newTeamAgentsInProject.insert(agent.id) }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10))
                                    Text(agent.name)
                                        .font(Typography.monoCaption)
                                }
                                .foregroundColor(isSelected ? Palette.accent : Palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? Palette.surfaceAccent : Palette.surface)
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? Palette.accent.opacity(0.4) : Palette.divider, lineWidth: 1)
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancelNewTeam)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)

                Button("Create", action: onCommitNewTeam)
                    .font(Typography.label)
                    .foregroundStyle(newTeamNameInProject.isEmpty ? Palette.textSecondary : Palette.accent)
                    .buttonStyle(.plain)
                    .disabled(newTeamNameInProject.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceAccentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
