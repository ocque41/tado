// Page anatomy primitives. Every Relay page composes from these
// three blocks per brief section 4:
//
// - `RelayPageContainer` — vertical padding (top 48, bottom 80),
//   horizontal padding (56 desktop / 24 narrow), max-width 1100,
//   scrollable.
// - `RelayPageHead` — kicker + h1 + lead.
// - `RelaySection` — kicker + h2 + body, with 56px gap between
//   sections.
//
// Use this template for every page including ones not enumerated
// in the brief — empty states, error pages, confirmations all open
// with kicker + h1 + lead.

import SwiftUI

// MARK: - PageContainer

struct RelayPageContainer<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.relayTheme) private var theme

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: RelaySpacing.sectionGap) {
                    content
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, RelaySpacing.pagePadTop)
                .padding(.bottom, RelaySpacing.pagePadBottom)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RelayPalette.background(for: theme))
        .scrollIndicators(.hidden)
    }

    private var horizontalPadding: CGFloat {
        // Brief: 56px desktop, 24px narrow. Geometry-aware switch
        // happens in App shell pass; for now use desktop default.
        RelaySpacing.pagePadX
    }
}

// MARK: - PageHead

struct RelayPageHead: View {
    let kicker: String
    let title: String
    let lead: String?
    /// h1 size — 60 default (desktop), 52 medium, 40 mobile.
    var h1Size: CGFloat = 60

    @Environment(\.relayTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RelayKicker(text: kicker)
                .padding(.bottom, 24)

            Text(title)
                .font(RelayType.h1(size: h1Size))
                .tracking(RelayTracking.h1(h1Size))
                .lineSpacing(0)
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let lead {
                Text(lead)
                    .font(RelayType.lead())
                    .lineSpacing(RelayType.lead().lineHeight(prose: true))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.top, 24)
            }
        }
    }
}

// MARK: - Section

struct RelaySection<Content: View, Trailing: View>: View {
    let kicker: String
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    @Environment(\.relayTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    RelayKicker(text: kicker)
                    Text(title)
                        .font(RelayType.h2())
                        .tracking(RelayTracking.h1(32) * 0.5)
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 16)
                trailing
            }
            content
        }
    }
}

extension RelaySection where Trailing == EmptyView {
    init(kicker: String, title: String, @ViewBuilder content: () -> Content) {
        self.kicker = kicker
        self.title = title
        self.content = content()
        self.trailing = EmptyView()
    }
}

// MARK: - Font line-height helper

private extension Font {
    /// Approx line-height advance — used for `.lineSpacing` calls.
    /// SwiftUI's `lineSpacing` is the *additional* leading on top
    /// of the font's intrinsic line height, so for prose we want
    /// roughly the body size × 0.6 to land near 1.6 line-height.
    func lineHeight(prose: Bool) -> CGFloat {
        prose ? 6 : 2
    }
}
