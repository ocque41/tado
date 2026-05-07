// Relay Kanban landing surface per brief section 6.10.
//
// The per-project Kanban view already lives at
// `Sources/Tado/Views/Projects/ProjectKanbanView.swift` and renders
// when a project is selected via Projects→detail→Kanban toggle.
// This standalone surface is a shortcut into that flow: it shows
// a project picker if there are multiple projects, and renders
// the active project's board if one is already selected.

import SwiftUI
import SwiftData

struct RelayKanbanView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Query(sort: \Project.createdAt) private var projects: [Project]

    var body: some View {
        if let id = appState.activeProjectID,
           let project = projects.first(where: { $0.id == id }) {
            // Reuse the existing ProjectKanbanView; it already
            // matches Tado's existing chrome.
            ProjectKanbanView(project: project)
        } else {
            picker
        }
    }

    private var picker: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "WORK — KANBAN",
                title: "Per-project board, mirrored to disk.",
                lead: "One board per project, mirrored to `.tado/kanban/state.json` so any agent can read or move cards via the `tado-kanban` CLI. Drop a markdown file in `inbox/` to add a card from outside.",
                h1Size: 52
            )
            if projects.isEmpty {
                RelayCard {
                    VStack(alignment: .leading, spacing: 12) {
                        RelayKicker(text: "NO PROJECTS")
                        Text("Add a project to see its Kanban board.")
                            .font(RelayType.h2(size: 22))
                            .foregroundStyle(RelayPalette.foreground(for: theme))
                        RelayInlineLink(label: "Open Projects", arrow: .forward) {
                            appState.currentView = .projects
                        }
                    }
                }
            } else {
                RelaySection(
                    kicker: "PICK A PROJECT",
                    title: "Each project keeps its own board.",
                    content: {
                        VStack(spacing: 0) {
                            ForEach(projects) { p in
                                pickerRow(p)
                            }
                        }
                    }
                )
            }
        }
    }

    private func pickerRow(_ p: Project) -> some View {
        Button(action: {
            appState.activeProjectID = p.id
            appState.projectPageMode = .kanban
        }) {
            HStack {
                Text(p.name)
                    .font(Typography.sans(size: 15, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Spacer()
                Text(p.rootPath)
                    .font(Typography.sans(size: 11, weight: .regular))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("OPEN →")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.terracotta)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RelayPalette.hairSoft(for: theme))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
