// Live status dots — the most important real-time signal in the
// app. Three variants per brief section 5.8:
//
// - `.running` — terracotta, 7px, infinite box-shadow pulse
//   (alpha 0.5 → 0 over 2s).
// - `.needsInput` — terracotta, 7px, no animation.
// - `.idle` — ink-4, 7px, no animation.
//
// Used in: workspace pill, every session row, every tile head, the
// Explore panel, eternal/dispatch run rows, the focused-tile
// modal head.
//
// Reduced-motion users see the running variant as a solid
// terracotta dot — no pulse — so the UI never animates against
// `accessibilityReduceMotion`.

import SwiftUI

enum RelayStatusKind {
    case running
    case needsInput
    case idle
}

struct RelayStatusDot: View {
    let kind: RelayStatusKind
    var size: CGFloat = 7

    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Halo (running only) — pulses out to 6px alpha 0.
            if kind == .running && !reduce {
                Circle()
                    .fill(RelayPalette.terracotta.opacity(pulse ? 0.0 : 0.5))
                    .frame(width: size + (pulse ? 12 : 0),
                           height: size + (pulse ? 12 : 0))
                    .animation(
                        .easeOut(duration: RelayMotionTokens.durStatusPulse)
                            .repeatForever(autoreverses: false),
                        value: pulse
                    )
            }
            Circle()
                .fill(coreColor)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(false)
        .accessibilityLabel(accessibilityName)
        .onAppear {
            if kind == .running && !reduce {
                pulse = true
            }
        }
    }

    private var coreColor: Color {
        switch kind {
        case .running, .needsInput:
            return RelayPalette.terracotta
        case .idle:
            return RelayPalette.foreground4(for: theme)
        }
    }

    private var accessibilityName: String {
        switch kind {
        case .running:    return "Status: running"
        case .needsInput: return "Status: needs input"
        case .idle:       return "Status: idle"
        }
    }
}
