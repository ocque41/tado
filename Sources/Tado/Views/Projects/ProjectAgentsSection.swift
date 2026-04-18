import SwiftUI

/// Agents disclosure zone — collapsible, collapsed by default. Lists
/// every agent `AgentDiscoveryService.discover` found for the project
/// with:
///
/// - Name (mono body)
/// - Source pill (`claude` / `codex`) colored by engine so the user
///   sees at a glance which harness owns the agent
/// - Team membership (e.g. "Frontend · Backend" when the agent is in
///   multiple teams; "(unassigned)" when not part of any team)
/// - Todo count — how many active todos this agent owns across all
///   teams in this project
///
/// Replaces the old "Available Agents" section that lived inside the
/// todos scroll. Giving agents their own zone makes the detail view's
/// hierarchy legible — todos are one thing, the roster of agents that
/// can run them is another.
struct ProjectAgentsSection: View {
    let project: Project
    let agents: [AgentDefinition]
    let projectTeams: [Team]
    let projectTodos: [TodoItem]
    @Binding var expanded: Bool

    @State private var isHeaderHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                body_
            }
        }
    }

    private var header: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded.toggle()
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 14)

                Text("AGENTS")
                    .font(Typography.callout)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textSecondary)

                Spacer()

                Text("\(agents.count) \(agents.count == 1 ? "agent" : "total")")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(isHeaderHovered ? Palette.hoverBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHeaderHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var body_: some View {
        if agents.isEmpty {
            Text("No agents discovered in .claude/agents/ or .codex/agents/")
                .font(Typography.body)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(agents) { agent in
                    agentRow(agent)
                }
            }
            .padding(.leading, 24)
            .padding(.bottom, 8)
        }
    }

    private func agentRow(_ agent: AgentDefinition) -> some View {
        let teamMemberships = projectTeams
            .filter { $0.agentNames.contains(agent.id) }
            .map(\.name)
        let agentTodos = projectTodos.filter { $0.agentName == agent.id }

        return HStack(spacing: 10) {
            Image(systemName: "person.circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)

            Text(agent.name)
                .font(Typography.monoBody)
                .foregroundStyle(Palette.textPrimary)

            sourcePill(for: agent.source)

            Spacer()

            Text(teamMembershipLabel(memberships: teamMemberships))
                .font(Typography.monoMicro)
                .foregroundStyle(teamMemberships.isEmpty ? Palette.textTertiary : Palette.textSecondary)

            if !agentTodos.isEmpty {
                Text("\(agentTodos.count) \(agentTodos.count == 1 ? "todo" : "todos")")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 5)
    }

    private func sourcePill(for source: AgentDefinition.AgentSource) -> some View {
        let (fg, bg): (Color, Color) = {
            switch source {
            case .claude: return (Palette.accent, Palette.accent.opacity(0.12))
            case .codex: return (Palette.success, Palette.success.opacity(0.15))
            }
        }()
        return Text(source.rawValue)
            .font(Typography.microBold)
            .tracking(0.5)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }

    /// "Frontend", "Frontend · Backend", or "(unassigned)" for agents
    /// not in any team. Kept short so the right edge of the row stays
    /// legible.
    private func teamMembershipLabel(memberships: [String]) -> String {
        if memberships.isEmpty {
            return "(unassigned)"
        }
        return memberships.joined(separator: " · ")
    }
}
