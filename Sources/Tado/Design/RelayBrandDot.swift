// 6×6 terracotta brand-mark dot. The single most repeated brand
// element in the redesign — once per major header zone (topbar
// brand cell, rail nav top section, narrow drawer head, palette
// foot, etc.). Use sparingly per brief section 5.7.

import SwiftUI

struct RelayBrandDot: View {
    /// Diameter in points. Default 6 per brief; the only other
    /// allowed size is 7 (live status dots).
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(RelayPalette.terracotta)
            .frame(width: size, height: size)
    }
}
