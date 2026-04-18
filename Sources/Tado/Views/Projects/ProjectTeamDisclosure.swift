import SwiftUI

/// One team rendered as an expandable disclosure. Structure:
///
/// - **Collapsed**: chevron (▸) + team name + stats (`5 todos · 2
///   agents`) + ••• menu on the right. Tap the header to expand.
/// - **Expanded**: chevron (▾) + same; body reveals each agent as a
///   subheader with its todos underneath. Each agent has a small
///   remove button (−). Below the agents, a FlowLayout of unassigned
///   agents lets the user add members as one-tap chips.
///
/// This replaces the old flat `teamSection` helper in
/// `ProjectDetailView` — same data, clearer visual hierarchy, and
/// the destructive "Delete team" action is one click deeper (in the
/// ••• menu) so it can't be hit accidentally while navigating.
struct ProjectTeamDisclosure: View {
    let team: Team
    let agents: [AgentDefinition]
    let projectTodos: [TodoItem]
    @Binding var expandedTeamID: UUID?
    let onDelete: () -> Void
    let onRemoveAgent: (String) -> Void
    let onAddAgent: (String) -> Void

    private var isExpanded: Bool {
        expandedTeamID == team.id
    }

    private var todoCount: Int {
        projectTodos.filter { $0.teamID == team.id }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                expandedBody
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 14)

                Text(team.name.uppercased())
                    .font(Typography.callout)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Text(statsLine)
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textSecondary)

                teamMenu
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statsLine: String {
        var parts: [String] = []
        parts.append("\(todoCount) \(todoCount == 1 ? "todo" : "todos")")
        let agentN = team.agentNames.count
        parts.append("\(agentN) \(agentN == 1 ? "agent" : "agents")")
        return parts.joined(separator: " · ")
    }

    private var teamMenu: some View {
        Menu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete team", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(team.agentNames), id: \.self) { agentName in
                agentBlock(agentName: agentName)
            }

            addAgentChips
        }
        .padding(.leading, 24)
        .padding(.bottom, 8)
    }

    private func agentBlock(agentName: String) -> some View {
        let agent = agents.first { $0.id == agentName }
        let agentTodos = projectTodos.filter { $0.teamID == team.id && $0.agentName == agentName }

        return VStack(alignment: .leading, spacing: 0) {
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

                if !agentTodos.isEmpty {
                    Text("\(agentTodos.count)")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                }

                Button(action: { onRemoveAgent(agentName) }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Remove agent from team")
            }
            .padding(.vertical, 6)

            if !agentTodos.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agentTodos) { todo in
                        TodoRowView(todo: todo)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private var addAgentChips: some View {
        let unassigned = agents.filter { !team.agentNames.contains($0.id) }
        if !unassigned.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Add")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)

                FlowLayout(spacing: 4) {
                    ForEach(unassigned) { agent in
                        Button(action: { onAddAgent(agent.id) }) {
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
            .padding(.top, 6)
        }
    }

    // MARK: - Interaction

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedTeamID = isExpanded ? nil : team.id
        }
    }
}
