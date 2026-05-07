// Keyboard pill — small kbd-glyph capsule. Used in the Jump
// (⌘K) button, palette foot, Explore foot, tweaks panel, and
// inline help text.
//
// Per brief section 3.3: 5.5px radius, `--color-wash` background,
// hairline border, 9px text, 3px×6px padding. Caps tracking.

import SwiftUI

struct RelayKbdPill: View {
    let text: String
    var fontSize: CGFloat = 9

    @Environment(\.relayTheme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(Typography.sans(size: fontSize, weight: .medium))
            .tracking(RelayTracking.kbd(fontSize))
            .foregroundStyle(RelayPalette.foreground2(for: theme))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .fill(RelayPalette.wash(for: theme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .accessibilityLabel("Keyboard shortcut \(text)")
    }
}
