import SwiftUI
import SwiftData

/// Sticky top navigation bar — sits above every page and replaces both
/// the floating bottom-left page switcher and the per-page breadcrumb
/// strip that lived inside `ProjectDetailView`.
///
/// Layout (left → right):
///
/// 1. **Tado wordmark** — `tado` set in Plus Jakarta Sans ExtraBold.
///    Doubles as a "go home" target: clicking it returns to the Todos
///    page (the default landing view).
/// 2. **Menu items** — one button per `ViewMode` (Canvas, Projects,
///    Todos), each with its SF Symbol icon + label in the brand font.
///    Re-clicking the active page resets that page's deep state — for
///    Projects, that means clearing `activeProjectID` so the user lands
///    back on the project list.
/// 3. **Spacer** — pushes the page-context cluster to the right edge.
/// 4. **Page title** — the name of whatever the user is currently
///    looking at: page name, or for Projects in detail mode, the
///    project's own name.
/// 5. **Actions menu** — the page's `⋯` menu, when one applies. Today
///    only the project detail page contributes one; other pages render
///    nothing so the slot collapses naturally.
///
/// The bar reads its rendering data from `AppState` + a few SwiftData
/// queries; every page-specific action is dispatched through the same
/// environment so no page has to re-declare its breadcrumb.
struct TopNavBar: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \Team.createdAt) private var teams: [Team]

    private var activeProject: Project? {
        guard appState.currentView == .projects,
              let id = appState.activeProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            wordmark
                .padding(.trailing, 22)

            HStack(spacing: 4) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    menuItem(for: mode)
                }
            }

            Spacer(minLength: 16)

            pageContext
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.surfaceElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)
        }
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        Button(action: {
            // Click the wordmark = go home. "Home" means the default
            // landing page (Todos) and any project drill-down clears.
            appState.activeProjectID = nil
            appState.showNewTeamForActiveProject = false
            appState.currentView = .todos
        }) {
            Text("tado")
                .font(Typography.sans(size: 18, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Palette.textPrimary)
        }
        .buttonStyle(.plain)
        .help("Tado")
    }

    // MARK: - Menu

    private func menuItem(for mode: ViewMode) -> some View {
        let isActive = appState.currentView == mode

        return Button(action: { selectMode(mode) }) {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.label)
                    .font(Typography.label)
            }
            .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Palette.surfaceAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectMode(_ mode: ViewMode) {
        // Re-clicking the current page resets that page's deep state.
        // For Projects this clears the drill-down so the user lands
        // back on the project list — equivalent to the old "← Projects"
        // breadcrumb button. Other pages have no equivalent state
        // today, so re-clicks are no-ops aside from the animation.
        if appState.currentView == mode {
            if mode == .projects {
                appState.activeProjectID = nil
                appState.showNewTeamForActiveProject = false
            }
            return
        }
        appState.currentView = mode
    }

    // MARK: - Page context (right side)

    /// The right cluster: page title, then any page-specific actions
    /// the current view contributes. Each page used to render its own
    /// header strip; that chrome lives here now so a project page, a
    /// todo page, and the canvas all share one nav bar with their
    /// actions slotted in.
    private var pageContext: some View {
        HStack(spacing: 10) {
            Text(pageTitle)
                .font(Typography.label)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            pageActions
        }
    }

    private var pageTitle: String {
        if let project = activeProject {
            return project.name
        }
        return appState.currentView.label
    }

    /// Whatever buttons / menus the current page wants in the nav bar.
    /// Empty for pages that have no chrome action today (Canvas,
    /// Todos). The project list contributes "+ New Project"; the
    /// project detail contributes the `⋯` actions menu (kept last so
    /// it sits at the very right edge as described in the brief).
    @ViewBuilder
    private var pageActions: some View {
        switch appState.currentView {
        case .projects:
            if let project = activeProject {
                projectActionsMenu(for: project)
            } else {
                newProjectButton
            }
        case .canvas, .todos, .extensions:
            EmptyView()
        }
    }

    /// "+ New Project" pill — same accent treatment as the empty-state
    /// CTA so the action reads as one consistent affordance whether it
    /// comes from the nav bar or the empty page body.
    private var newProjectButton: some View {
        Button(action: { appState.showNewProjectSheet = true }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New Project")
                    .font(Typography.label)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.surfaceAccent)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The `⋯` menu surfaced for the current project. Mirrors the
    /// items the old in-page breadcrumb exposed; bootstrap + delete
    /// route through `ProjectActionsService` so the list view, the
    /// detail view, and this bar share one implementation.
    private func projectActionsMenu(for project: Project) -> some View {
        let projectTeams = teams.filter { $0.projectID == project.id }

        return Menu {
            Button(action: { appState.showNewTeamForActiveProject = true }) {
                Label("New team…", systemImage: "person.3.sequence")
            }
            Divider()
            Button(action: {
                ProjectActionsService.bootstrapTools(
                    project: project,
                    modelContext: modelContext,
                    terminalManager: terminalManager,
                    appState: appState
                )
            }) {
                Label("Bootstrap A2A tools", systemImage: "wrench.and.screwdriver")
            }
            Button(action: {
                ProjectActionsService.bootstrapTeam(
                    project: project,
                    teams: projectTeams,
                    modelContext: modelContext,
                    terminalManager: terminalManager,
                    appState: appState
                )
            }) {
                Label("Bootstrap team awareness", systemImage: "person.3")
            }
            .disabled(projectTeams.isEmpty)
            Button(action: {
                ProjectActionsService.bootstrapAutoMode(
                    project: project,
                    modelContext: modelContext,
                    terminalManager: terminalManager,
                    appState: appState
                )
            }) {
                Label("Bootstrap Claude auto mode", systemImage: "lock.open.rotation")
            }
            Button(action: {
                ProjectActionsService.bootstrapKnowledge(
                    project: project,
                    modelContext: modelContext,
                    terminalManager: terminalManager,
                    appState: appState
                )
            }) {
                Label("Bootstrap knowledge layer", systemImage: "brain.head.profile")
            }
            Divider()
            Button(role: .destructive, action: {
                ProjectActionsService.deleteProject(
                    project,
                    modelContext: modelContext,
                    terminalManager: terminalManager
                )
                appState.activeProjectID = nil
            }) {
                Label("Delete project", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
