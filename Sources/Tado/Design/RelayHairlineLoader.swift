// Non-determinate loader — a 1px terracotta hairline animating
// left-to-right at 1.2s linear infinite. Replaces ProgressView /
// spinners / skeletons throughout the app per brief section 11.
//
// Reduce-motion fallback: a static thin terracotta hairline.

import SwiftUI

struct RelayHairlineLoader: View {
    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Static base — paints under the moving sliver so
                // there is always a visible hairline (and the
                // reduce-motion path uses this alone).
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)
                if !reduce {
                    Rectangle()
                        .fill(RelayPalette.terracotta)
                        .frame(width: geo.size.width * 0.3, height: 1)
                        .offset(x: phase * geo.size.width)
                } else {
                    Rectangle()
                        .fill(RelayPalette.terracotta.opacity(0.5))
                        .frame(height: 1)
                }
            }
        }
        .frame(height: 1)
        .accessibilityLabel("Loading")
        .onAppear {
            guard !reduce else { return }
            withAnimation(.linear(duration: RelayMotionTokens.durLoader)
                            .repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}
