// Relay top navigation bar — 56px horizontal nav per brief
// section 3.2.1.
//
// Layout (left → right):
//
//   [brand-mark + TADO + BY CUMULUS]    [hairline]    [workspace pill]    [11 nav items]    [⌘K Jump]
//
// Responsive collapse (brief, exact px):
//
// - <1280: nav-item padding shrinks to 7×4, font 10. Hide brand-mark
//   subtitle. Hide workspace meta ("N NEEDS INPUT" text).
// - <1080: each nav item collapses to its numeral only.
// - <880:  workspace pill → just its dot. Jump button label hides.
// - <760:  full-width drawer pattern (handled in Phase 2 ‒ App
//   shell pass — for now the topbar simply tightens further).
//
// Active nav-item state: numeral + name turn ink, plus a 1px
// terracotta underline running the inset width of the item.
//
// Brand decision: the spec calls for "mono" text in nav cells; Tado
// renders Plus Jakarta Sans throughout per single-family rule.
//
// Active nav for a given `ViewMode` is read from
// `AppState.currentView`; clicking sets it.

import SwiftUI
import SwiftData

struct RelayTopNavBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]

    /// Width threshold-driven collapse: which compaction tier to
    /// render. Re-evaluated via `GeometryReader` in `body`.
    @State private var width: CGFloat = 1440

    /// 11 nav items, in the brief's order.
    /// (Todos / Canvas / Kanban / Projects / Teams / Sessions /
    /// Dispatch / Knowledge / Eternal / Pets / Settings.)
    static let navOrder: [ViewMode] = [
        .todos, .canvas, .kanban, .projects, .teams,
        .sessions, .dispatch, .knowledge, .eternal, .pets, .settings,
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            content
                .onAppear { width = w }
                .onChange(of: w) { _, newValue in width = newValue }
        }
        .frame(height: 56)
    }

    private var content: some View {
        HStack(spacing: 0) {
            brandCell
                .padding(.leading, 20)
                .padding(.trailing, 16)

            verticalHair(height: 22)

            workspacePill
                .padding(.leading, 16)
                .padding(.trailing, 12)

            navStrip
                .frame(maxWidth: .infinity, alignment: .leading)

            jumpButton
                .padding(.leading, 12)
                .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }

    // MARK: - Brand mark

    private var brandCell: some View {
        Button(action: {
            appState.activeProjectID = nil
            appState.showNewTeamForActiveProject = false
            appState.currentView = .details
        }) {
            HStack(spacing: 10) {
                RelayBrandDot(size: 6)
                if width >= 1080 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TADO")
                            .font(Typography.sans(size: 11, weight: .semibold))
                            .tracking(RelayTracking.brand(11))
                            .foregroundStyle(RelayPalette.foreground(for: theme))
                        if width >= 1280 {
                            Text("BY CUMULUS")
                                .font(Typography.sans(size: 9, weight: .regular))
                                .tracking(RelayTracking.caps(9))
                                .foregroundStyle(RelayPalette.foreground3(for: theme))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tado — go home")
    }

    // MARK: - Workspace pill

    /// Shows the active project + needs-input count. Click opens
    /// the Explore panel (wired in Phase 4). For now, click is a
    /// no-op so the pill renders but does not navigate; Phase 4
    /// adds the binding.
    private var workspacePill: some View {
        let needsInput = todos.filter {
            $0.status == .needsInput || $0.status == .awaitingResponse
        }.count
        let activeName = chipLabel
        return Button(action: {
            // Phase 4 — open Explore. Until then, swap to Details.
            appState.currentView = .details
        }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(RelayPalette.foreground(for: theme))
                    .frame(width: 7, height: 7)
                if width >= 880 {
                    Text(activeName)
                        .font(Typography.sans(size: 11, weight: .regular))
                        .tracking(RelayTracking.meta(11))
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                    if width >= 1280 {
                        verticalHair(height: 14)
                        Text(needsInput > 0 ? "\(needsInput) NEEDS INPUT" : "ALL IDLE")
                            .font(Typography.sans(size: 9, weight: .medium))
                            .tracking(RelayTracking.caps(9))
                            .foregroundStyle(needsInput > 0
                                ? RelayPalette.terracotta
                                : RelayPalette.foreground3(for: theme))
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
        }
        .buttonStyle(.plain)
        .help("Workspace · click for Explore")
    }

    private var chipLabel: String {
        // Match TopNavBar's old logic: active project name or "tado · core".
        if let id = appState.activeProjectID {
            // ContentView injects ModelContext; the workspace name
            // is best read from there. For now show "tado · core".
            _ = id
        }
        return "tado · core"
    }

    // MARK: - Nav strip

    /// 11 nav items + a fade mask on the right edge. Brief mandates
    /// no scrollbar — the mask-image gradient (24px linear-gradient
    /// to transparent) is the affordance for "more is offscreen".
    private var navStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(Self.navOrder.enumerated()), id: \.element) { idx, mode in
                    navCell(index: idx, mode: mode)
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    @State private var hoveredMode: ViewMode? = nil

    private func navCell(index: Int, mode: ViewMode) -> some View {
        let active = (appState.currentView == mode)
        let hovered = (hoveredMode == mode)
        let foreground = active
            ? RelayPalette.foreground(for: theme)
            : (hovered
                ? RelayPalette.foreground(for: theme)
                : RelayPalette.foreground3(for: theme))
        let numeralColor = active
            ? (width >= 1080 ? RelayPalette.foreground(for: theme) : RelayPalette.terracotta)
            : RelayPalette.foreground4(for: theme)

        return Button(action: { selectMode(mode) }) {
            HStack(spacing: 6) {
                Text(String(format: "%02d", index + 1))
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(numeralColor)
                if width >= 1080 {
                    Text(mode.label)
                        .font(Typography.sans(size: navLabelSize, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(foreground)
                }
            }
            .padding(.horizontal, navItemPadH)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) {
                if active {
                    Rectangle()
                        .fill(RelayPalette.terracotta)
                        .frame(height: 1)
                        .padding(.horizontal, navItemPadH * 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { hovering in
            hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
        }
    }

    private var navItemPadH: CGFloat {
        width < 1280 ? 7 : 9
    }
    private var navLabelSize: CGFloat {
        width < 1280 ? 10 : 12
    }

    private func selectMode(_ mode: ViewMode) {
        if appState.currentView == mode {
            if mode == .projects {
                appState.activeProjectID = nil
                appState.showNewTeamForActiveProject = false
            }
            return
        }
        // Window-routed surfaces open their dedicated extension
        // window instead of switching the main view. This is a
        // pragmatic Phase 1 routing — Phase 9/11/13 redesign each
        // window's contents and Phase 5/6/7/8/10/12 build the
        // dedicated surfaces inside the main window when needed.
        switch mode {
        case .knowledge:
            openWindow(id: ExtensionWindowID.string(for: DomeExtension.manifest.id))
        case .pets:
            openWindow(id: ExtensionWindowID.string(for: PetsExtension.manifest.id))
        case .settings:
            appState.showSettings = true
        default:
            appState.currentView = mode
        }
    }

    // MARK: - Jump button

    private var jumpButton: some View {
        Button(action: {
            // Phase 3 wires this to the ⌘K palette overlay.
            // Phase 1 stub: do nothing.
        }) {
            HStack(spacing: 10) {
                Text("›")
                    .font(Typography.sans(size: 14, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                if width >= 880 {
                    Text("Jump")
                        .font(Typography.sans(size: 12, weight: .regular))
                        .tracking(RelayTracking.meta(12))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                }
                RelayKbdPill(text: "⌘K")
            }
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Open command palette · ⌘K")
    }

    // MARK: - Helpers

    private func verticalHair(height: CGFloat) -> some View {
        Rectangle()
            .fill(RelayPalette.hair(for: theme))
            .frame(width: 1, height: height)
    }
}
