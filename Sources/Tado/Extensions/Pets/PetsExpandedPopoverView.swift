import SwiftUI
import AppKit

/// SwiftUI content of the click-to-expand popover. Hosted
/// inside the `NSPopover` from
/// `PetsFloatingPanelController.toggleExpandedPopover`.
///
/// What it renders
/// - Header — "Tado is busy / quiet — N active surfaces".
/// - Per-project breakdown. Each project is one collapsible
///   row with its sessions and runs underneath. Rows that drive
///   the current pet state (e.g. the run that triggered a
///   perf regression) are flagged with an accent.
/// - Footer — `/hatch` shortcut, `Pet settings`, and
///   `Tuck away pet` (mirrors the settings window's enable
///   toggle).
///
/// Deep-link affordances
/// `[Open ▸]` on a session row activates the main Tado window
/// and posts `.petsDeepLinkRequest` with the todoID. The canvas
/// listens for that notification (wiring lives in `CanvasView`)
/// and scrolls the matching tile into view, mirroring the
/// existing `appState.focusedTileTodoID` flow.
struct PetsExpandedPopoverView: View {
    let coordinator: PetsCoordinator
    let onCloseRequested: () -> Void

    @State private var collapsedProjects: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 360, height: 420)
        .padding(0)
        .background(Color.black.opacity(0.92))
    }

    // MARK: - Header

    private var header: some View {
        let aggregate = coordinator.aggregate
        let title: String = {
            switch aggregate.state {
            case .perfRegressed:    return "Perf regression caught"
            case .awaitingResponse: return "Tado needs you"
            case .eternalRunning:   return "Eternal running"
            case .running:          return "Tado is busy"
            case .needsInput:       return "Idle — input pending"
            case .done:             return "Just finished"
            case .idle:             return "Tado is quiet"
            }
        }()

        let subtitle: String = {
            if aggregate.totalActive == 0 { return "No active surfaces." }
            return "\(aggregate.totalActive) active surface\(aggregate.totalActive == 1 ? "" : "s")"
                + (aggregate.totalNeedsInput > 0
                    ? " · \(aggregate.totalNeedsInput) waiting on you"
                    : "")
        }()

        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content list

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if coordinator.aggregate.perProject.isEmpty {
                    EmptyContent()
                        .padding(.top, 60)
                } else {
                    ForEach(coordinator.aggregate.perProject) { project in
                        projectGroup(project)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func projectGroup(_ project: PetProjectStatus) -> some View {
        let isCollapsed = collapsedProjects.contains(project.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isCollapsed { collapsedProjects.remove(project.id) }
                else { collapsedProjects.insert(project.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(project.sessions.count + project.runs.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(project.sessions) { row in
                    sessionRow(row)
                }
                ForEach(project.runs) { row in
                    runRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ row: PetSessionRow) -> some View {
        HStack(spacing: 8) {
            statusBadge(row.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("[\(gridLabel(row.gridIndex))] · \(relativeAge(row.startedAt))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button("Open") {
                deepLinkToTodo(row.todoID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08))
            .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func runRow(_ row: PetRunRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.kind == .eternal ? "infinity" : "shippingbox")
                .font(.system(size: 11))
                .foregroundStyle(row.isDriver ? .orange : .white.opacity(0.6))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(row.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(row.isDriver ? .orange.opacity(0.85) : .white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let colour: Color = {
            switch status {
            case "awaitingResponse": return .yellow
            case "needsInput":       return .blue
            case "running":          return .green
            case "completed":        return .gray
            case "failed":           return .red
            default:                 return .white.opacity(0.5)
            }
        }()
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.openHatchSheet(prefilled: "")
                onCloseRequested()
            } label: {
                Label("Hatch", systemImage: "sparkles")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))

            Button {
                openSettingsWindow()
                onCloseRequested()
            } label: {
                Label("Pet settings", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))

            Spacer()

            Button {
                coordinator.toggleVisible()
                onCloseRequested()
            } label: {
                Label("Tuck away", systemImage: "moon.zzz")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func gridLabel(_ index: Int) -> String {
        // Mirror the canvas grid notation used in
        // `tado-list` so the popover and the CLI agree.
        let cols = ScopedConfig.shared.get().canvas.gridColumns
        let row = index / max(1, cols) + 1
        let col = index % max(1, cols) + 1
        return "\(row),\(col)"
    }

    private func relativeAge(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60      { return "\(elapsed)s" }
        if elapsed < 3600    { return "\(elapsed / 60)m" }
        if elapsed < 86_400  { return "\(elapsed / 3600)h" }
        return "\(elapsed / 86_400)d"
    }

    private func deepLinkToTodo(_ todoID: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .petsDeepLinkRequest,
            object: nil,
            userInfo: ["todoID": todoID]
        )
        onCloseRequested()
    }

    private func openSettingsWindow() {
        let id = ExtensionWindowID.string(for: PetsExtension.manifest.id)
        if #available(macOS 14.0, *) {
            // `openWindow` is only accessible from inside a
            // SwiftUI environment; AppKit fallback uses
            // `NSWorkspace.open(url:)` indirectly.
            // Simpler: post a notification the main window
            // listens for and translates into `openWindow(id:)`.
            NotificationCenter.default.post(
                name: .openExtensionWindowRequest,
                object: nil,
                userInfo: ["id": id]
            )
        }
    }
}

/// Empty-state copy when no projects have any active surfaces.
private struct EmptyContent: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.stars")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.45))
            Text("No active surfaces")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Tado will wake the pet when work starts.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

extension Notification.Name {
    /// Posted by the pets popover when the user clicks `[Open]`
    /// on a session row. CanvasView observes this and applies
    /// `appState.focusedTileTodoID` to scroll the tile into
    /// view, the same way Cross-Run Browser deep-links work.
    public static let petsDeepLinkRequest = Notification.Name("PetsDeepLinkRequest")

    /// Posted by the popover when the user clicks `Pet settings`.
    /// The main TadoApp scene listens and calls `openWindow(id:)`.
    public static let openExtensionWindowRequest = Notification.Name("OpenExtensionWindowRequest")
}
