import SwiftUI

/// EditorialCard — the one Cumulus container.
///
/// 5.5px radius, 1px hairline border, no shadow, holds a typographic
/// composition. Per /Users/miguel/Documents/cumulus/CUMULUS-BRAND.md.
///
/// The chrome is constant; the typography inside is free.
struct EditorialCard<Content: View>: View {
    var fill: Color = Palette.background
    var border: Color = Palette.divider
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 5.5)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5.5)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}
