// Inline link — Plus Jakarta Sans 11px medium with 1px hairline
// bottom border. Always trails with `→` (forward) or `←` (back).
// Hover deepens the underline + text to ink (full).
//
// Per brief section 5.6.

import SwiftUI

struct RelayInlineLink: View {
    enum Arrow {
        case forward, back, none
    }

    let label: String
    var arrow: Arrow = .forward
    var action: () -> Void

    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(displayLabel)
                    .font(Typography.sans(size: 11, weight: .medium))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(textColor)
            }
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .relayFocusRing(focused)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isLink)
        .onHover { newValue in
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                hover = newValue
            }
        }
    }

    private var displayLabel: String {
        switch arrow {
        case .forward: return "\(label) →"
        case .back:    return "← \(label)"
        case .none:    return label
        }
    }

    private var textColor: Color {
        hover
            ? RelayPalette.foreground(for: theme)
            : RelayPalette.foreground(for: theme)
    }

    private var borderColor: Color {
        hover
            ? RelayPalette.foreground(for: theme)
            : RelayPalette.hair(for: theme)
    }
}
