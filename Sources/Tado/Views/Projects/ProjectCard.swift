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
    let onDispatch: () -> Void
    let onStart: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                // Row 1 — identity
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(project.name)
                        .font(Typography.titleLg)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
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
                if isDispatching {
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    /// State-driven pill on the right of row 1. Hidden for idle projects —
    /// the absence of a capsule is itself a signal ("no dispatch going on").
    @ViewBuilder
    private var dispatchStatusCapsule: some View {
        let state = project.dispatchState
        if state == "idle" || state.isEmpty {
            EmptyView()
        } else if state == "drafted" {
            capsule(label: "DRAFTED", fg: Palette.warning, bg: Palette.warning.opacity(0.12))
        } else if state == "planning" {
            capsule(label: "PLANNING", fg: Palette.accent, bg: Palette.accent.opacity(0.12))
        } else if state == "dispatching" {
            capsule(label: "DISPATCHING", fg: Palette.accent, bg: Palette.accent.opacity(0.22))
        } else {
            capsule(label: state.uppercased(), fg: Palette.textSecondary, bg: Palette.surface)
        }
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
                Label(project.dispatchState == "idle" || project.dispatchState.isEmpty
                      ? "New Dispatch…"
                      : "Edit Dispatch…",
                      systemImage: "doc.text.badge.plus")
            }
            // "Start" lives in the menu here temporarily — Step 3 will move
            // it into the detail view's dispatch card as the primary CTA.
            // Until then, keep it reachable so the workflow never stalls.
            Button(action: onStart) {
                Label("Start dispatching", systemImage: "play.fill")
            }
            .disabled(project.dispatchState == "idle" || project.dispatchState.isEmpty)
            Divider()
            Button(action: onBootstrapTools) {
                Label("Bootstrap A2A tools", systemImage: "wrench.and.screwdriver")
            }
            Button(action: onBootstrapTeam) {
                Label("Bootstrap team awareness", systemImage: "person.3")
            }
            .disabled(!hasTeams)
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
        project.dispatchState == "dispatching"
    }
}
