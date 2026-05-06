import SwiftUI

/// One project in the list view, rendered as a four-row card:
///
/// - **Row 1**: name (titleLg) + dispatch status capsule.
/// - **Row 2**: project path (monoCaption, middle-truncated).
/// - **Row 3**: stats line (`12 todos · 3 teams · 5 agents`) + index badge.
/// - **Row 4**: explicit action buttons — `+ Dispatch` / `Start`,
///   bootstrap quartet (A2A / Team / Auto / Knowledge), and a
///   trailing `Delete`. All visible, all named — no ••• menu.
///
/// **No more ••• menu** — the v0.18 → v0.19 design pass replaced the
/// hidden-behind-ellipsis actions with an explicit action row at the
/// bottom of every card. Every per-project action shows up under the
/// project it belongs to, with its own label, instead of being one
/// tap of a menu away. The `Bootstrap …` quartet is grouped behind a
/// short `bootstrap:` overline so the eye reads "primary actions ·
/// bootstrap actions · destructive" without each button needing to
/// repeat the word *Bootstrap*.
///
/// Tap the card body (anywhere outside the action buttons) to open
/// the project — the outer `.onTapGesture` handles that, while the
/// inner Buttons capture their own taps by SwiftUI hit-testing
/// priority.
///
/// When `project.dispatchState == "dispatching"` (or any Eternal
/// run is live), a 2 px accent left border signals active work at a
/// glance.
struct ProjectCard: View {
    let project: Project
    let todoCount: Int
    let teamCount: Int
    let agentCount: Int
    let hasTeams: Bool
    let onTap: () -> Void
    let onBootstrapTools: () -> Void
    let onBootstrapTeam: () -> Void
    let onBootstrapAutoMode: () -> Void
    let onBootstrapKnowledge: () -> Void
    let onDispatch: () -> Void
    let onStart: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        // v0.18 design pass: cards drop their rounded corners and
        // raised fill, flattening into structural rows that sit
        // inside the parent `SectionRail`. Each card is still fully
        // clickable; the leading 2 px accent stripe still flags
        // active dispatch / eternal runs at a glance.
        //
        // The card is a `Button(action: onTap)` so SwiftUI's hit-test
        // priority gives inner Buttons (Dispatch / Start / Bootstrap
        // / Delete) precedence — a tap inside any inner button fires
        // only that button's action, never the outer card's `onTap`.
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    // Row 1 — identity
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(project.name)
                            .font(Font.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        if isEternalRunning {
                            eternalGlyph
                        }
                        dispatchStatusCapsule
                        Spacer(minLength: 0)
                    }

                    // Row 2 — path
                    Text(project.rootPath)
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Row 3 — stats + index badge
                    HStack(alignment: .center, spacing: 12) {
                        Text(statsLine)
                            .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink3)
                        CodeIndexBadge(projectID: project.id.uuidString.lowercased())
                        Spacer()
                    }
                }

                // Hairline separator between info + actions.
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: DK.ruleW)

                // Row 4 — explicit action row.
                actionsRow
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Palette.bgRowHi : Palette.bgElev)
            .overlay(alignment: .leading) {
                if isDispatching || isEternalRunning {
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Action row

    /// Explicit per-project actions. Three groups separated visually:
    /// run controls (left), bootstrap quartet (middle, behind a short
    /// `bootstrap:` overline so the labels can stay short), and a
    /// destructive `Delete` on the far right.
    ///
    /// Wrapping each line so the row can flow on narrow widths is
    /// handled by `FlowLayout`; on a typical card width every button
    /// fits on a single line.
    private var actionsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            // Run controls
            OutlineButton(
                project.dispatchRuns.isEmpty ? "+ Dispatch" : "+ Dispatch run",
                size: .small,
                variant: .accent,
                action: onDispatch
            )
            .help("Open the dispatch composer for this project")

            OutlineButton(
                "Start",
                size: .small,
                variant: .standard,
                action: onStart
            )
            .disabled(!hasReadyDispatch)
            .help(hasReadyDispatch
                  ? "Start the latest ready/planning dispatch"
                  : "No ready dispatch to start")

            // Group separator + bootstrap label.
            Rectangle()
                .fill(Palette.rule)
                .frame(width: DK.ruleW, height: 18)
                .padding(.horizontal, 4)

            OverlineLabel("bootstrap", tint: Palette.ink4)

            OutlineButton("A2A", size: .small, variant: .standard, action: onBootstrapTools)
                .help("Bootstrap A2A tools (CLAUDE.md / AGENTS.md)")
            OutlineButton("Team", size: .small, variant: .standard, action: onBootstrapTeam)
                .disabled(!hasTeams)
                .help(hasTeams
                      ? "Bootstrap team awareness (re-inject roster)"
                      : "Add a team first to enable team-awareness bootstrap")
            OutlineButton("Auto", size: .small, variant: .standard, action: onBootstrapAutoMode)
                .help("Bootstrap Claude auto mode (permission policy)")
            OutlineButton("Knowledge", size: .small, variant: .standard, action: onBootstrapKnowledge)
                .help("Bootstrap knowledge layer (Dome second brain)")

            Spacer(minLength: 8)

            // Destructive — far right, danger variant.
            OutlineButton("Delete", size: .small, variant: .danger, action: onDelete)
                .help("Delete this project (asks for confirmation)")
        }
    }

    /// Whether at least one dispatch run is in a state that `Start`
    /// can act on.
    private var hasReadyDispatch: Bool {
        project.dispatchRuns.contains { $0.state == "ready" || $0.state == "planning" }
    }

    // MARK: - Pieces

    /// State-driven pill on the right of row 1. Shows the worst-active
    /// state across the project's dispatches (since a project may have
    /// multiple concurrent runs). Priority order: dispatching >
    /// planning > drafted. Hidden when no runs are active — absence
    /// of a capsule is itself a signal ("no dispatch going on").
    /// Uses the shared `StatusPill` so list cards and the project
    /// detail page render identical chrome.
    @ViewBuilder
    private var dispatchStatusCapsule: some View {
        if let state = mostActiveDispatchState {
            StatusPill.runState(state)
        } else {
            EmptyView()
        }
    }

    /// Worst-active state across this project's dispatch runs, or nil when
    /// every run is terminal (or there are none). Priority reflects
    /// "user-impact": dispatching > ready > planning > drafted.
    private var mostActiveDispatchState: String? {
        let activeOrder = ["dispatching", "ready", "planning", "drafted"]
        for state in activeOrder {
            if project.dispatchRuns.contains(where: { $0.state == state }) {
                return state
            }
        }
        return nil
    }

    private func capsule(label: String, fg: Color, bg: Color) -> some View {
        Text(label)
            .font(Typography.microBold)
            .tracking(0.8)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    /// `12 todos · 3 teams · 5 agents` — omits zero-count segments so a
    /// brand-new project reads as "0 todos" only (no "0 teams · 0 agents"
    /// clutter).
    private var statsLine: String {
        var parts: [String] = []
        parts.append("\(todoCount) \(todoCount == 1 ? "todo" : "todos")")
        if teamCount > 0 {
            parts.append("\(teamCount) \(teamCount == 1 ? "team" : "teams")")
        }
        if agentCount > 0 {
            parts.append("\(agentCount) \(agentCount == 1 ? "agent" : "agents")")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var isDispatching: Bool {
        project.dispatchRuns.contains { $0.state == "dispatching" }
    }

    private var isEternalRunning: Bool {
        project.eternalRuns.contains { $0.state == "running" }
    }

    /// Visual-only infinity indicator — shows the card has a live Eternal
    /// session. Tapping anywhere on the card opens the project detail page
    /// (where the full Eternal section lives), so the glyph itself doesn't
    /// need a separate tap handler.
    private var eternalGlyph: some View {
        Image(systemName: "infinity")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.accent.opacity(0.14))
            .clipShape(Capsule())
            .help("Eternal running — open this project to see details.")
    }
}
