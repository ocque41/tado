// Editorial card — the base container for every grouped data
// surface. 5.5px radius, hairline border, paper/ink bg per theme,
// 28×32 padding, NO shadow.
//
// Per brief section 5.1. Hairlines do the work — never combine
// `RelayCard` with a shadow modifier.

import SwiftUI

struct RelayCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(
        top: RelaySpacing.cardPadV,
        leading: RelaySpacing.cardPadH,
        bottom: RelaySpacing.cardPadV,
        trailing: RelaySpacing.cardPadH
    )
    var fill: Bool = true
    @ViewBuilder var content: Content

    @Environment(\.relayTheme) private var theme

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .fill(fill
                        ? RelayPalette.background(for: theme)
                        : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
    }
}

/// Convenience initializer with no padding — for tight cards
/// (e.g. focused-tile head).
extension RelayCard {
    init(noPadding: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = noPadding
            ? EdgeInsets()
            : EdgeInsets(top: RelaySpacing.cardPadV,
                         leading: RelaySpacing.cardPadH,
                         bottom: RelaySpacing.cardPadV,
                         trailing: RelaySpacing.cardPadH)
        self.fill = true
        self.content = content()
    }
}
