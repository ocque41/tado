// Stat block — the visual anchor of every page that has a stat
// strip. 72pt display weight 300 numeral, 10px caps label, 10px
// caps meta. Stats live in a four-column grid separated by
// hairlines (no outer borders).
//
// Per brief section 5.2.

import SwiftUI

struct RelayStat: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var meta: String? = nil
    /// Tint for `meta` — defaults to `foreground3`. Only override
    /// for the live-state meta (e.g. terracotta for "live"
    /// indicators).
    var metaTint: Color? = nil

    init(_ label: String, _ value: String, meta: String? = nil, metaTint: Color? = nil) {
        self.label = label
        self.value = value
        self.meta = meta
        self.metaTint = metaTint
    }
}

struct RelayStatStrip: View {
    let stats: [RelayStat]

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { idx, stat in
                if idx > 0 {
                    Rectangle()
                        .fill(RelayPalette.hair(for: theme))
                        .frame(width: 1)
                }
                RelayStatCell(stat: stat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }
}

struct RelayStatCell: View {
    let stat: RelayStat

    @Environment(\.relayTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RelayKicker(text: stat.label)
            Text(stat.value)
                .font(RelayType.stat())
                .tracking(RelayTracking.tight(72))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
            if let m = stat.meta {
                Text(m.uppercased())
                    .font(Typography.sans(size: 10, weight: .regular))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(stat.metaTint ?? RelayPalette.foreground3(for: theme))
            }
        }
    }
}
