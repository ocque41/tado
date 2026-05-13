// Relay Projects landing surface per brief section 6.5.
//
// Page anatomy + a 2-column grid of project cards. Clicking a card
// drills into the existing ProjectDetailView (preserved via the
// .projects route's existing ProjectsView). For Phase 7 the
// landing replaces the legacy ProjectListView's chrome; the
// detail view (when a project is selected) still falls through
// to the legacy ProjectsView.

import SwiftUI
import SwiftData

struct RelayProjectsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \Team.createdAt) private var teams: [Team]
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]

    var body: some View {
        // Drill-down: when an active project is selected, render
        // either the Relay-redesigned detail view or the per-
        // project Kanban board, mirroring the legacy
        // ProjectsView.body switch.
        if let id = appState.activeProjectID,
           let project = projects.first(where: { $0.id == id }) {
            if appState.projectPageMode == .kanban {
                ProjectKanbanView(project: project)
            } else {
                RelayProjectDetailView(project: project)
            }
        } else {
            list
        }
    }

    private var list: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "STRUCTURE — PROJECTS",
                title: "\(projects.count) \(projects.count == 1 ? "project" : "projects") · \(teamsCount) \(teamsCount == 1 ? "agent" : "agents").",
                lead: "Projects group todos under a directory.",
                h1Size: 52
            )

            if projects.isEmpty {
                emptyState
            } else {
                projectsGrid
            }
        }
    }

    private var teamsCount: Int {
        teams.reduce(0) { acc, t in acc + t.agentNames.count }
    }

    private var emptyState: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 16) {
                RelayKicker(text: "NO PROJECTS")
                Text("Add a project to get started.")
                    .font(RelayType.h2(size: 24))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text("A project links a directory to Tado.")
                    .font(Typography.sans(size: 14, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
                    .frame(maxWidth: 600, alignment: .leading)
                    .lineSpacing(2)
                RelayButton(label: "New Project", variant: .primary) {
                    appState.showNewProjectSheet = true
                }
            }
        }
    }

    private var projectsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]
        return LazyVGrid(columns: cols, spacing: 24) {
            ForEach(projects) { project in
                projectCard(project)
            }
            // "+ New project" card
            newProjectCard
        }
    }

    private func projectCard(_ p: Project) -> some View {
        let agentCount = teams
            .filter { $0.projectID == p.id }
            .reduce(0) { acc, t in acc + t.agentNames.count }
        let todoCount = todos.filter { $0.projectID == p.id && $0.listState == .active }.count
        let teamRow = teams.first(where: { $0.projectID == p.id })

        return Button(action: {
            appState.activeProjectID = p.id
        }) {
            RelayCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name)
                                .font(Typography.sans(size: 22, weight: .light))
                                .foregroundStyle(RelayPalette.foreground(for: theme))
                            Text(p.rootPath)
                                .font(Typography.sans(size: 11, weight: .regular))
                                .tracking(RelayTracking.meta(11))
                                .foregroundStyle(RelayPalette.foreground3(for: theme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(timeAgo(p.createdAt).uppercased())
                            .font(Typography.sans(size: 9, weight: .medium))
                            .tracking(RelayTracking.caps(9))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                    }

                    Rectangle()
                        .fill(RelayPalette.hairSoft(for: theme))
                        .frame(height: 1)

                    metaRow(label: "AGENTS", value: "\(agentCount)")
                    metaRow(label: "TODOS",  value: "\(todoCount)")
                    metaRow(label: "TEAM",   value: teamRow?.name ?? "—")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.sans(size: 10, weight: .medium))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            Text(value)
                .font(Typography.sans(size: 15, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
        }
    }

    private var newProjectCard: some View {
        Button(action: { appState.showNewProjectSheet = true }) {
            VStack(alignment: .leading, spacing: 16) {
                RelayKicker(text: "+ NEW PROJECT")
                Text("Add a directory to track.")
                    .font(Typography.sans(size: 18, weight: .light))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(RelayPalette.hair(for: theme))
            )
        }
        .buttonStyle(.plain)
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
