import SwiftUI
import SwiftData

/// Top-level Projects page. Owns the list-vs-detail routing — when a
/// project is selected (`appState.activeProjectID != nil`), the detail
/// view takes over; otherwise the list view renders.
///
/// The selected-project ID lives in `AppState` so the global top nav
/// bar can read it (to render the project name as the page title and
/// expose its actions menu) and clear it (to navigate back to the list
/// when the user re-clicks "Projects" in the menu).
struct ProjectsView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Project.createdAt) private var projects: [Project]

    private var selectedProject: Project? {
        guard let id = appState.activeProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let project = selectedProject {
                ProjectDetailView(project: project)
            } else {
                ProjectListView(
                    onSelect: { project in
                        appState.activeProjectID = project.id
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
    }
}
