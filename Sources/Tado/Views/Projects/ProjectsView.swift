import SwiftUI
import SwiftData

/// Top-level Projects page. Owns the list-vs-detail routing — when a
/// project is selected (`selectedProjectID != nil`), the detail view
/// takes over; otherwise the list view renders. All per-mode state
/// (forms, pickers, inline toggles) lives in the respective child
/// views so this stays a thin gate.
struct ProjectsView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @State private var selectedProjectID: UUID? = nil

    private var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let project = selectedProject {
                ProjectDetailView(
                    project: project,
                    onBack: {
                        selectedProjectID = nil
                        appState.activeProjectID = nil
                    }
                )
            } else {
                ProjectListView(
                    onSelect: { project in
                        selectedProjectID = project.id
                        appState.activeProjectID = project.id
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
    }
}
