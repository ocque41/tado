// Settings row — the three-column pattern (label+help / value /
// control) per brief section 5.4. 24px gap, 16–20px vertical
// padding, bottom hairline.
//
// Two control variants ship: `RelayToggle` (32×18 pill) and
// `RelaySegmented` (segmented buttons). More variants accrue as
// surfaces are migrated.

import SwiftUI

// MARK: - Row

struct RelaySettingsRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: Control
    var bottomDivider: Bool = true

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased())
                    .font(Typography.sans(size: 10, weight: .medium))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                if let help {
                    Text(help)
                        .font(Typography.sans(size: 13, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                        .frame(maxWidth: 480, alignment: .leading)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, RelaySpacing.rowPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if bottomDivider {
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - Toggle

struct RelayToggle: View {
    @Binding var isOn: Bool

    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: {
            withAnimation(RelayAnim.standard(reduce: reduce, dur: RelayMotionTokens.durNormal)) {
                isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: RelayRadius.pill)
                    .fill(Color.clear)
                    .frame(width: 32, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayRadius.pill)
                            .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
                    )
                Circle()
                    .fill(isOn
                        ? RelayPalette.terracotta
                        : RelayPalette.foreground(for: theme))
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Segmented

struct RelaySegmentedOption<T: Hashable>: Identifiable {
    var id: T { value }
    let label: String
    let value: T
}

struct RelaySegmented<T: Hashable>: View {
    let options: [RelaySegmentedOption<T>]
    @Binding var selection: T

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { opt in
                segmentButton(opt)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
    }

    private func segmentButton(_ opt: RelaySegmentedOption<T>) -> some View {
        let active = opt.value == selection
        return Button(action: { selection = opt.value }) {
            Text(opt.label.uppercased())
                .font(Typography.sans(size: 10, weight: .semibold))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(active
                    ? (theme == .ink ? RelayPalette.inkSolid : RelayPalette.paperSolid)
                    : RelayPalette.foreground2(for: theme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    active
                        ? RelayPalette.foreground(for: theme)
                        : Color.clear
                )
        }
        .buttonStyle(.plain)
    }
}
