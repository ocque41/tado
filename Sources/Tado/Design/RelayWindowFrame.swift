// Lightweight Relay window-frame wrapper.
//
// Used to put a Relay page-head (kicker + h1 + lead) above an
// existing complex body whose internals don't need rewriting.
// Phase 9 / 11 / 13 use this to land the page-anatomy contract on
// the Dome / Pets / Cross-Run Browser / Notifications windows
// without rewriting their working surface bodies.
//
// The wrapper:
// - Renders an unscrolled `RelayPageHead` at the top.
// - Below it, the caller's existing view fills the remaining
//   height (no scroll wrapper — the caller's own scroll views
//   handle paging through long content).
// - Theme-aware background paints behind both.

import SwiftUI

struct RelayWindowFrame<Content: View>: View {
    let kicker: String
    let title: String
    let lead: String?
    /// h1 size — defaults to 40 (window-internal scale). Pages that
    /// want the full hero use 52/60.
    var h1Size: CGFloat = 40
    /// Inset for the head block. Pages that want the head flush
    /// with the window edge can pass 0; default is the page padding.
    var headPadding: EdgeInsets = EdgeInsets(top: 36, leading: 32, bottom: 24, trailing: 32)
    @ViewBuilder var content: Content

    @Environment(\.relayTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                RelayKicker(text: kicker)
                Text(title)
                    .font(RelayType.h1(size: h1Size))
                    .tracking(RelayTracking.h1(h1Size))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .accessibilityAddTraits(.isHeader)
                if let lead {
                    Text(lead)
                        .font(RelayType.lead())
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                        .frame(maxWidth: 720, alignment: .leading)
                        .lineSpacing(2)
                }
            }
            .padding(headPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RelayPalette.background(for: theme))
    }
}
