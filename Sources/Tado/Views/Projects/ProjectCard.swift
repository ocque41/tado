import SwiftUI

/// One project in the list view, rendered as a three-row card:
///
/// - **Row 1**: name (titleLg) + dispatch status capsule.
/// - **Row 2**: project path (monoCaption, middle-truncated).
/// - **Row 3**: stats line (`12 todos · 3 teams · 5 agents`) + ••• menu.
///
/// Tap the card body to open the project. The ••• menu exposes the
/// per-project rare actions (bootstrap tools / bootstrap team /
/// delete) that were previously tiny icons crammed into the row.
///
/// When `project.dispatchState == "dispatching"`, a 2 px accent
/// left border signals active work at a glance.
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
    let onDispatch: () -> Void
    let onStart: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                // Row 1 — identity
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(project.name)
                        .font(Typography.titleLg)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    if isEternalRunning {
                        eternalGlyph
                    }
                    dispatchStatusCapsule
                }

                // Row 2 — context
                Text(project.rootPath)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Row 3 — stats + menu
                HStack(alignment: .center, spacing: 12) {
                    Text(statsLine)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    actionsMenu
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceElevated)
            .overlay(alignment: .leading) {
                if isDispatching || isEternalRunning {
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: 2)
                }
            }
            .overlay(
                Rectangle()
                    .fill(isHovered ? Palette.hoverBackground : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Pieces

    /// State-driven pill on the right of row 1. Shows the worst-active state
    /// across the project's dispatches (since the project may have multiple
    /// concurrent runs). Priority order: dispatching > planning > drafted.
    /// Hidden when no runs are active — the absence of a capsule is itself
    /// a signal ("no dispatch going on").
    @ViewBuilder
    private var dispatchStatusCapsule: some View {
        if let state = mostActiveDispatchState {
            switch state {
            case "drafted":
                capsule(label: "DRAFTED", fg: Palette.warning, bg: Palette.warning.opacity(0.12))
            case "planning":
                capsule(label: "PLANNING", fg: Palette.accent, bg: Palette.accent.opacity(0.12))
            case "ready":
                capsule(label: "READY", fg: Palette.success, bg: Palette.success.opacity(0.15))
            case "dispatching":
                capsule(label: "DISPATCHING", fg: Palette.accent, bg: Palette.accent.opacity(0.22))
            default:
                capsule(label: state.uppercased(), fg: Palette.textSecondary, bg: Palette.surface)
            }
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

    private var actionsMenu: some View {
        Menu {
            Button(action: onDispatch) {
                Label(project.dispatchRuns.isEmpty
                      ? "New Dispatch…"
                      : "New Dispatch run…",
                      systemImage: "doc.text.badge.plus")
            }
            // "Start" triggers phase 1 of the most-recently-created READY
            // dispatch. When there's none, the card's onStart handler shows
            // the "plan not ready" alert.
            Button(action: onStart) {
                Label("Start latest dispatch", systemImage: "play.fill")
            }
            .disabled(!project.dispatchRuns.contains(where: { $0.state == "ready" || $0.state == "planning" }))
            Divider()
            Button(action: onBootstrapTools) {
                Label("Bootstrap A2A tools", systemImage: "wrench.and.screwdriver")
            }
            Button(action: onBootstrapTeam) {
                Label("Bootstrap team awareness", systemImage: "person.3")
            }
            .disabled(!hasTeams)
            Button(action: onBootstrapAutoMode) {
                Label("Bootstrap Claude auto mode", systemImage: "lock.open.rotation")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete project", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
