// Relay shell — composes the titlebar accessory + the right nav
// (topbar / rail / narrow drawer trigger) + the page content.
//
// Used by ContentView to replace the standalone `RelayTopNavBar()`
// call. The shell picks the right nav based on:
//
// - Window width: <760 → narrow burger button (drawer pattern).
// - User preference: `@AppStorage("relay.navMode")` toggles between
//   topbar (default) and rail when ≥760px.
//
// The shell does NOT own the page tree — the caller passes its
// content as a child closure. This keeps the body of ContentView
// readable: shell + page tree + sheets, all attached at the same
// level.

import SwiftUI

struct RelayShell<Content: View>: View {
    @Environment(\.relayTheme) private var theme
    @AppStorage("relay.navMode") private var navModeRaw: String = RelayNavMode.topbar.rawValue
    @State private var width: CGFloat = 1440
    @State private var drawerOpen: Bool = false

    /// Surface name shown in the titlebar accessory.
    var surfaceName: String?
    /// Page tree below the nav.
    @ViewBuilder var content: Content

    private var navMode: RelayNavMode {
        RelayNavMode(rawValue: navModeRaw) ?? .topbar
    }

    var body: some View {
        GeometryReader { geo in
            shellBody(width: geo.size.width)
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in width = newValue }
        }
    }

    @ViewBuilder
    private func shellBody(width: CGFloat) -> some View {
        let useDrawer = width < 760

        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                RelayTitlebarAccessory(surfaceName: surfaceName)
                if useDrawer {
                    narrowTopbar
                }
                bodyAfterTitlebar(useDrawer: useDrawer)
            }
            // Drawer overlays the whole shell (under the titlebar
            // already because the drawer is a ZStack inside this
            // outer ZStack).
            RelayNavOverlayDrawer(isPresented: $drawerOpen)
        }
    }

    @ViewBuilder
    private func bodyAfterTitlebar(useDrawer: Bool) -> some View {
        if useDrawer {
            // Just content — narrow topbar already mounted above.
            content
        } else if navMode == .rail {
            HStack(spacing: 0) {
                RelayRailNav()
                content
            }
        } else {
            VStack(spacing: 0) {
                RelayTopNavBar()
                    .zIndex(1)
                content
            }
        }
    }

    private var narrowTopbar: some View {
        HStack(spacing: 0) {
            // Left: brand mark
            HStack(spacing: 8) {
                RelayBrandDot()
                Text("TADO")
                    .font(Typography.sans(size: 11, weight: .semibold))
                    .tracking(RelayTracking.brand(11))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }
            .padding(.leading, 16)

            Spacer()

            // Right: burger + Jump
            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.24)) {
                        drawerOpen = true
                    }
                }) {
                    Text("☰  NAV")
                        .font(Typography.sans(size: 10, weight: .medium))
                        .tracking(RelayTracking.caps(10))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .overlay(
                            RoundedRectangle(cornerRadius: RelayRadius.standard)
                                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Open navigation drawer")

                Button(action: {
                    // Phase 3 — palette wiring.
                }) {
                    HStack(spacing: 4) {
                        Text("›")
                            .font(Typography.sans(size: 12, weight: .regular))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                        RelayKbdPill(text: "⌘K")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayRadius.standard)
                            .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .help("Open command palette · ⌘K")
            }
            .padding(.trailing, 16)
        }
        .frame(height: 56)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }
}
