// Button family. Four variants per brief section 5.5:
//
// - `.btn`         — paper bg, hairline border, ink text.
// - `.btnPrimary`  — ink bg, paper text. Hover: terracotta bg.
// - `.btnGhost`    — no border, ink-2 text. Hover: ink text.
// - `.btnTiny`     — 4×9 padding, mono 9px caps. For row-end actions.
//
// **Never combine fill + shadow + icon** on the same button.

import SwiftUI

enum RelayButtonVariant {
    case standard
    case primary
    case ghost
    case tiny
    case destructive  // terracotta border + text, no fill
}

struct RelayButton: View {
    let label: String
    var variant: RelayButtonVariant = .standard
    var icon: String? = nil
    var action: () -> Void

    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                }
                Text(transformedLabel)
                    .font(Typography.sans(size: textSize, weight: textWeight))
                    .tracking(textTracking)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, padX)
            .padding(.vertical, padY)
            .background(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .relayFocusRing(focused)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .onHover { newValue in
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                hover = newValue
            }
        }
    }

    // MARK: - Variant-driven values

    private var transformedLabel: String {
        // Tiny variant uses uppercase tracking for "data" feel.
        variant == .tiny ? label.uppercased() : label.uppercased()
    }
    private var textSize: CGFloat {
        switch variant {
        case .tiny:                                 return 9
        case .standard, .primary, .ghost, .destructive: return 11
        }
    }
    private var textWeight: Font.Weight {
        switch variant {
        case .tiny, .ghost: return .medium
        default: return .semibold
        }
    }
    private var textTracking: CGFloat {
        switch variant {
        case .tiny: return RelayTracking.kbd(9)
        default:    return RelayTracking.caps(11)
        }
    }
    private var iconSize: CGFloat {
        variant == .tiny ? 9 : 11
    }
    private var padX: CGFloat {
        switch variant {
        case .tiny: return 9
        default:    return 16
        }
    }
    private var padY: CGFloat {
        switch variant {
        case .tiny: return 4
        default:    return 8
        }
    }

    private var textColor: Color {
        switch variant {
        case .standard, .ghost:
            return hover
                ? RelayPalette.foreground(for: theme)
                : (variant == .ghost
                    ? RelayPalette.foreground2(for: theme)
                    : RelayPalette.foreground(for: theme))
        case .primary:
            return hover
                ? RelayPalette.paperSolid // light text on hovered terracotta bg
                : (theme == .ink ? RelayPalette.inkSolid : RelayPalette.paperSolid)
        case .tiny:
            return hover
                ? RelayPalette.foreground(for: theme)
                : RelayPalette.foreground2(for: theme)
        case .destructive:
            return RelayPalette.terracotta
        }
    }

    private var fillColor: Color {
        switch variant {
        case .standard, .ghost, .tiny, .destructive:
            return Color.clear
        case .primary:
            return hover
                ? RelayPalette.terracotta
                : RelayPalette.foreground(for: theme)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .standard:
            return hover
                ? RelayPalette.foreground(for: theme)
                : RelayPalette.hair(for: theme)
        case .primary:
            return hover
                ? RelayPalette.terracotta
                : RelayPalette.foreground(for: theme)
        case .ghost:
            return Color.clear
        case .tiny:
            return hover
                ? RelayPalette.foreground(for: theme)
                : RelayPalette.hair(for: theme)
        case .destructive:
            return RelayPalette.terracotta
        }
    }
}
