// Outlined status pill — uppercase mono-substitute caps, hairline
// border, 5.5px radius, no fill by default (`.outline`). Used in
// the recent todos list, sessions table, eternal/dispatch run
// rows, anywhere a status is rendered as text not as a dot.
//
// Variants per brief section 5.3:
// - `.outline` (default) — paper/ink bg, hairline border, ink text.
// - `.strike` — ink-3 text + strikethrough; for failed/done states.
// - `.soft` — wash background, no border; soft fill alternative.
//
// Live status pills also accept a leading `RelayStatusDot`
// rendered inline.

import SwiftUI

enum RelayPillVariant {
    case outline
    case strike
    case soft
}

struct RelayPill: View {
    let label: String
    var variant: RelayPillVariant = .outline
    /// Optional leading status dot. When set, the pill renders
    /// the dot before the label inside the same hairline-bordered
    /// capsule.
    var statusDot: RelayStatusKind? = nil

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let kind = statusDot {
                RelayStatusDot(kind: kind, size: 6)
            }
            Text(label.uppercased())
                .font(Typography.sans(size: 10, weight: .semibold))
                .tracking(RelayTracking.caps(10))
                .strikethrough(variant == .strike, color: textColor)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(fillColor)
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
        .accessibilityLabel(label)
    }

    private var textColor: Color {
        switch variant {
        case .outline: return RelayPalette.foreground(for: theme)
        case .strike:  return RelayPalette.foreground3(for: theme)
        case .soft:    return RelayPalette.foreground(for: theme)
        }
    }

    private var fillColor: Color {
        switch variant {
        case .outline, .strike: return .clear
        case .soft:             return RelayPalette.wash(for: theme)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .outline, .strike: return RelayPalette.hair(for: theme)
        case .soft:             return .clear
        }
    }
}
