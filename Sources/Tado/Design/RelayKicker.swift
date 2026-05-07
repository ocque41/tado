// Page kicker — the small uppercase identifier above every h1.
// Per brief section 4: "01 — TODOS" pattern (mono 10px tracking
// 0.20em color ink-3 uppercase). Tado renders Plus Jakarta Sans
// at the same size + tracking + caps treatment instead of JBM
// (single-family brand decision).

import SwiftUI

struct RelayKicker: View {
    let text: String
    var fontSize: CGFloat = 10

    @Environment(\.relayTheme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(Typography.sans(size: fontSize, weight: .medium))
            .tracking(RelayTracking.caps(fontSize))
            .foregroundStyle(RelayPalette.foreground3(for: theme))
            .accessibilityAddTraits(.isHeader)
    }
}
