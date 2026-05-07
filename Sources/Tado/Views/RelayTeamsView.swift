// Relay Teams surface per brief section 6.6.
//
// Lists every team across every project. No card chrome — each
// team is a horizontal row with name + project + agent list.

import SwiftUI
import SwiftData

struct RelayTeamsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @Query(sort: \Project.createdAt) private var projects: [Project]

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "STRUCTURE — TEAMS",
                title: "\(teams.count) \(teams.count == 1 ? "team" : "teams") of named agents.",
                lead: "Group agents into named teams for coordinated multi-agent work. Each agent definition lives at `.claude/agents/<name>.md`.",
                h1Size: 52
            )

            if teams.isEmpty {
                emptyState
            } else {
                teamsList
            }
        }
    }

    private var emptyState: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                RelayKicker(text: "NO TEAMS YET")
                Text("Add agents to a project to form a team.")
                    .font(RelayType.h2(size: 22))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }
        }
    }

    private var teamsList: some View {
        VStack(spacing: 0) {
            ForEach(teams) { team in
                teamRow(team: team)
            }
        }
    }

    private func teamRow(team: Team) -> some View {
        let project = projects.first(where: { $0.id == team.projectID })
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(team.name)
                    .font(Typography.sans(size: 26, weight: .light))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text("PROJECT · \((project?.name ?? "—").uppercased())")
                    .font(Typography.sans(size: 10, weight: .medium))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            .frame(width: 200, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(team.agentNames, id: \.self) { agent in
                    HStack {
                        Text(agent)
                            .font(Typography.sans(size: 13, weight: .regular))
                            .foregroundStyle(RelayPalette.foreground(for: theme))
                        Spacer()
                        Text(".CLAUDE/AGENTS/\(agent.uppercased()).MD")
                            .font(Typography.sans(size: 10, weight: .regular))
                            .tracking(RelayTracking.caps(10))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(RelayPalette.hairSoft(for: theme))
                            .frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                RelayButton(label: "Edit", variant: .ghost) {
                    appState.activeProjectID = team.projectID
                }
            }
        }
        .padding(.vertical, 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }
}
