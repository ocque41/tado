import SwiftUI
import SwiftData

/// Sticky 44 pt top navigation bar — the design pass that landed in
/// v0.18 reshapes this strip to match the projects-page mockup:
///
/// 1. **Brand cell** — `tado` set in mono 600, with a 6 × 6 amber
///    accent square trailing it. Click returns to the Todos view.
/// 2. **Nav strip** — four equal cells (Canvas / Projects / Todos /
///    Extensions), each with its SF Symbol + label, separated by
///    1 px vertical hairlines. The active cell paints its row
///    background `bgRowHi` and gets a 2 px accent underline.
/// 3. **Right cluster** — keyboard hint (⌘ K) + `UserChip` showing
///    the active project (or "tado" when on a global page).
///
/// Page-specific actions used to live here too — that role moves
/// inside `PageHeader` per page now, so the bar carries chrome only.
/// Action menus that need to follow the page are dispatched from the
/// new `PageHeader` so each page owns its own contextual controls.
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

    /// Explicit four-cell strip — `.details` is intentionally absent
    /// here. The Tado wordmark on the left is its affordance, mirroring
    /// the "Tado / Canvas / Projects / Todos / Extensions" hierarchy
    /// the user laid out (one global home + four contextual workspaces).
    /// `Ctrl+Tab` cycling still includes `.details` because it iterates
    /// `ViewMode.allCases`, so the page remains keyboard-reachable.
    private static let stripModes: [ViewMode] = [.canvas, .projects, .todos, .extensions]

    var body: some View {
        HStack(spacing: 0) {
            brandCell
                .padding(.leading, 16)
                .padding(.trailing, 14)

            Rectangle()
                .fill(Palette.rule)
                .frame(width: DK.ruleW, height: 44)

            ForEach(Self.stripModes, id: \.self) { mode in
                navCell(for: mode)
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: DK.ruleW, height: 44)
            }

            Spacer(minLength: 12)

            rightCluster
                .padding(.trailing, 16)
        }
        .frame(height: 44)
        .background(Palette.bgElev)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }

    // MARK: - Brand

    /// 6 × 6 terracotta dot + mono 600 wordmark. Per the Cumulus
    /// master brand spec (CUMULUS-BRAND.md "Logo system"): the brand
    /// mark is a true-circle terracotta dot to the LEFT of the
    /// product wordmark. Click navigates to Details (the live status
    /// dashboard) and clears any project drill-down so the wordmark
    /// functions as the global "go home" affordance.
    private var brandCell: some View {
        Button(action: {
            appState.activeProjectID = nil
            appState.showNewTeamForActiveProject = false
            appState.currentView = .details
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 6, height: 6)
                Text("tado")
                    .font(Font.system(size: 14, weight: .semibold, design: .monospaced))
                    .tracking(-0.2)
                    .foregroundStyle(Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tado — go home (Details)")
    }

    // MARK: - Nav cell

    @State private var hoveredMode: ViewMode? = nil

    private func navCell(for mode: ViewMode) -> some View {
        let isActive = appState.currentView == mode
        let isHovered = hoveredMode == mode
        return Button(action: { selectMode(mode) }) {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.label)
                    .font(Font.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(isActive ? Palette.ink : Palette.ink3)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                ZStack(alignment: .bottom) {
                    if isActive {
                        Palette.bgRowHi
                    } else if isHovered {
                        Palette.bgRow.opacity(0.5)
                    }
                    if isActive {
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(height: 2)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
        }
    }

    private func selectMode(_ mode: ViewMode) {
        // Re-clicking the current page resets that page's deep state.
        // For Projects this clears the drill-down so the user lands
        // back on the project list. Other pages have no equivalent
        // state today.
        if appState.currentView == mode {
            if mode == .projects {
                appState.activeProjectID = nil
                appState.showNewTeamForActiveProject = false
            }
            return
        }
        appState.currentView = mode
    }

    // MARK: - Right cluster (keyboard hint + user chip)

    private var rightCluster: some View {
        // Just the user chip on the right. The earlier `⌘K` keycap
        // hint was removed in v0.19 — the shortcut wasn't wired to
        // anything (no command palette exists), so showing it set up
        // an expectation the app couldn't honour.
        UserChip(label: chipLabel, dotColor: chipDot)
    }

    /// Either the active project's name or "tado" when on a global
    /// page (Canvas, Todos, Extensions, or the project list with
    /// nothing selected). Mirrors the chip in the design mockup.
    private var chipLabel: String {
        if let activeProject {
            return activeProject.name
        }
        return "tado"
    }

    /// Live-dot colour. Green when an Eternal run is live for the
    /// chip's project (or any project, when chipLabel == "tado");
    /// amber when only Dispatch is mid-flight; otherwise the muted
    /// green default so the chip never reads as offline.
    private var chipDot: Color {
        let projectsForChip: [Project]
        if let activeProject {
            projectsForChip = [activeProject]
        } else {
            projectsForChip = projects
        }
        if projectsForChip.contains(where: { p in p.eternalRuns.contains(where: { $0.state == "running" }) }) {
            return Palette.green
        }
        if projectsForChip.contains(where: { p in p.dispatchRuns.contains(where: { $0.state == "dispatching" || $0.state == "planning" }) }) {
            return Palette.accent
        }
        return Palette.green.opacity(0.55)
    }
}
