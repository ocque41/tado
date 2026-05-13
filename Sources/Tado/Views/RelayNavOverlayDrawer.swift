// Narrow-viewport (<760px) full-width drawer per brief section 3.4.
//
// Triggered from a menu/burger button in the topbar (added at very
// narrow widths). Slides in from the leading edge as a 280px paper-
// background panel with a `rgba(26,26,26,0.45)` scrim + 6px backdrop
// blur.
//
// Tapping a nav item closes the drawer.

import SwiftUI

struct RelayNavOverlayDrawer: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if isPresented {
                // Scrim
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .background(.ultraThinMaterial)
                    .onTapGesture {
                        dismiss()
                    }
                    .transition(.opacity)
                // Drawer
                HStack(spacing: 0) {
                    drawerBody
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                        .background(RelayPalette.background(for: theme))
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(RelayPalette.hair(for: theme))
                                .frame(width: 1)
                        }
                        .transition(.move(edge: .leading))
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(RelayAnim.drawer(reduce: reduce), value: isPresented)
    }

    private var drawerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RelayBrandDot()
                Text("TADO")
                    .font(Typography.sans(size: 11, weight: .semibold))
                    .tracking(RelayTracking.brand(11))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Spacer()
                Button(action: dismiss) {
                    Text("✕")
                        .font(Typography.sans(size: 14, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(RelayTopNavBar.navOrder.enumerated()), id: \.element) { idx, mode in
                        navRow(index: idx, mode: mode)
                    }
                }
            }
        }
    }

    private func navRow(index: Int, mode: ViewMode) -> some View {
        let active = appState.currentView == mode
        return Button(action: {
            selectMode(mode)
            dismiss()
        }) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1))
                    .font(Typography.sans(size: 11, weight: .medium))
                    .tracking(RelayTracking.caps(11))
                    .foregroundStyle(active
                        ? RelayPalette.terracotta
                        : RelayPalette.foreground3(for: theme))
                    .frame(width: 24, alignment: .leading)
                Text(mode.label)
                    .font(Typography.sans(size: 13, weight: .medium))
                    .foregroundStyle(active
                        ? RelayPalette.foreground(for: theme)
                        : RelayPalette.foreground2(for: theme))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(active ? RelayPalette.wash(for: theme) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RelayPalette.hairSoft(for: theme))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dismiss() {
        withAnimation(RelayAnim.drawer(reduce: reduce)) {
            isPresented = false
        }
    }

    private func selectMode(_ mode: ViewMode) {
        switch mode {
        case .knowledge:
            openWindow(id: ExtensionWindowID.string(for: DomeExtension.manifest.id))
        case .settings:
            appState.showSettings = true
        default:
            appState.currentView = mode
        }
    }
}
