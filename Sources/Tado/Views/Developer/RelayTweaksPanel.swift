// Developer-facing tweaks panel — bottom-right floating panel
// per brief section 9. Two segmented controls (nav mode + theme)
// + three buttons (open Explore, open palette, spawn flash toast).
// Persists state via @AppStorage so a relaunch preserves it.
//
// Toggle visibility via the menu item "Window → Relay Tweaks"
// (added in Phase 13). For now the panel is always visible at
// the bottom-right corner of the main window when
// `RELAY_TWEAKS_VISIBLE` env or AppStorage flag is set.

import SwiftUI

struct RelayTweaksPanel: View {
    @AppStorage("relay.navMode") private var navModeRaw: String = RelayNavMode.topbar.rawValue
    @AppStorage("relay.tweaksVisible") private var visible: Bool = false
    @Environment(RelayThemeStore.self) private var themeStore
    @Environment(\.relayTheme) private var theme

    var navMode: Binding<RelayNavMode> {
        Binding(
            get: { RelayNavMode(rawValue: navModeRaw) ?? .topbar },
            set: { navModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        if !visible {
            EmptyView()
        } else {
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RelayKicker(text: "RELAY · TWEAKS")
                Spacer(minLength: 8)
                Button(action: { visible = false }) {
                    Text("✕")
                        .font(Typography.sans(size: 12, weight: .medium))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                }
                .buttonStyle(.plain)
                .help("Hide tweaks panel")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("NAV MODE")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                RelaySegmented(
                    options: [
                        RelaySegmentedOption(label: "Topbar", value: RelayNavMode.topbar),
                        RelaySegmentedOption(label: "Rail",   value: RelayNavMode.rail),
                    ],
                    selection: navMode
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("THEME")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                RelaySegmented(
                    options: [
                        RelaySegmentedOption(label: "Ink",   value: RelayTheme.ink),
                        RelaySegmentedOption(label: "Paper", value: RelayTheme.paper),
                    ],
                    selection: Binding(
                        get: { themeStore.theme },
                        set: { themeStore.theme = $0 }
                    )
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .fill(RelayPalette.background(for: theme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .shadow(
            color: RelayShadow.modalColor,
            radius: RelayShadow.modalRadius,
            x: RelayShadow.modalX,
            y: RelayShadow.modalY
        )
        .frame(width: 240)
        .padding(.trailing, 24)
        .padding(.bottom, 24)
    }
}
