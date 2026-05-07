// Titlebar accessory bar — 32px treatment per brief section 3.1.
//
// Shows: window title (mono uppercase tracked), version pill, and
// a paper/ink theme toggle button. Painted as an overlay at the
// top edge of every WindowGroup root via `.overlay(alignment: .top)`.
//
// Macos draws the traffic-light buttons on top of any view; this
// accessory leaves the leftmost ~80px clear for them.

import SwiftUI

struct RelayTitlebarAccessory: View {
    /// Surface name to display center-stage. Pass `nil` for windows
    /// that don't track a primary surface (Pets, etc.) — the title
    /// then renders just "TADO".
    let surfaceName: String?

    @Environment(\.relayTheme) private var theme
    @Environment(RelayThemeStore.self) private var themeStore

    var body: some View {
        HStack(spacing: 12) {
            // Leftmost padding clears the traffic lights.
            Spacer()
                .frame(width: 80)
            Spacer()
            Text(centeredTitle.uppercased())
                .font(Typography.sans(size: 12, weight: .regular))
                .tracking(RelayTracking.caps(12))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            HStack(spacing: 12) {
                versionPill
                themeToggle
            }
            .padding(.trailing, 14)
        }
        .frame(height: 32)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }

    private var centeredTitle: String {
        if let n = surfaceName, !n.isEmpty {
            return "Tado · \(n)"
        }
        return "Tado"
    }

    private var versionPill: some View {
        Text("v\(Self.appVersion)")
            .font(Typography.sans(size: 10, weight: .regular))
            .tracking(RelayTracking.caps(10))
            .foregroundStyle(RelayPalette.foreground3(for: theme))
    }

    private var themeToggle: some View {
        Button(action: {
            themeStore.toggle()
        }) {
            Text(themeStore.theme == .ink ? "PAPER" : "INK")
                .font(Typography.sans(size: 10, weight: .regular))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
        .buttonStyle(.plain)
        .help("Toggle paper / ink")
        .keyboardShortcut("t", modifiers: .command)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3"
    }
}
