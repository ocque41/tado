// 64px-wide vertical rail nav per brief section 3.2.2.
//
// Alternate to RelayTopNavBar — toggled by the user via the
// RelayTweaksPanel ("nav mode" segmented). Layout:
//
// - Top section (60px tall): brand-mark dot only, centered, with
//   bottom hairline. Click → Explore (Phase 4) or Details for now.
// - Middle section: 11 numeral cells, mono 11px, hover → tooltip
//   pill, active → 2px×18px terracotta bar at left edge.
// - Bottom section (60px tall): ⌘K hint, top hairline. Click →
//   palette (Phase 3 binding).

import SwiftUI

struct RelayRailNav: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hoveredMode: ViewMode? = nil

    var body: some View {
        VStack(spacing: 0) {
            topSection
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(RelayTopNavBar.navOrder.enumerated()), id: \.element) { idx, mode in
                        railCell(index: idx, mode: mode)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            bottomSection
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(width: 1)
        }
    }

    private var topSection: some View {
        Button(action: {
            // Phase 4 — open Explore. Placeholder: open Details.
            appState.currentView = .details
        }) {
            RelayBrandDot(size: 7)
                .frame(width: 64, height: 60)
        }
        .buttonStyle(.plain)
        .help("Open Explore")
    }

    private func railCell(index: Int, mode: ViewMode) -> some View {
        let active = (appState.currentView == mode)
        let hovered = (hoveredMode == mode)
        return Button(action: { selectMode(mode) }) {
            ZStack {
                if active {
                    HStack {
                        Rectangle()
                            .fill(RelayPalette.terracotta)
                            .frame(width: 2, height: 18)
                        Spacer()
                    }
                }
                Text(String(format: "%02d", index + 1))
                    .font(Typography.sans(size: 11, weight: .medium))
                    .tracking(RelayTracking.caps(11))
                    .foregroundStyle(active || hovered
                        ? RelayPalette.foreground(for: theme)
                        : RelayPalette.foreground3(for: theme))
            }
            .frame(width: 64, height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if hovered {
                    railTooltip(mode: mode)
                        .padding(.leading, 76)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { hovering in
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
            }
        }
    }

    private func railTooltip(mode: ViewMode) -> some View {
        Text(mode.label.uppercased())
            .font(Typography.sans(size: 10, weight: .medium))
            .tracking(RelayTracking.caps(10))
            .foregroundStyle(theme == .ink ? RelayPalette.inkSolid : RelayPalette.paperSolid)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .fill(RelayPalette.foreground(for: theme))
            )
            .fixedSize()
    }

    private var bottomSection: some View {
        Button(action: {
            // Phase 3 wires this to the palette.
        }) {
            Text("⌘K")
                .font(Typography.sans(size: 9, weight: .medium))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
                .frame(width: 64, height: 60)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Open command palette · ⌘K")
    }

    private func selectMode(_ mode: ViewMode) {
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
}
