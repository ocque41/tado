import SwiftUI

/// Right-side scroll area of the crafted.md review modal. Renders a
/// flat sequence of `MarkdownBlock`s and tags every heading with an
/// `.id(slug)` so the parent modal can drive scroll position from the
/// sidebar via `ScrollViewReader.scrollTo(slug)`.
struct CraftedReviewBody: View {
    let blocks: [MarkdownBlock]
    let scrollProxy: ScrollViewProxy
    @Binding var selectedSlug: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                    MarkdownBlockView(block: block)
                        .id(blockID(idx: idx, block: block))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
    }

    /// Headings get the slug as their id so the sidebar's `scrollTo`
    /// lands precisely. Non-headings get a per-index synthetic id so
    /// SwiftUI doesn't warn about duplicate ids.
    private func blockID(idx: Int, block: MarkdownBlock) -> String {
        if case let .heading(_, _, slug) = block {
            return slug
        }
        return "block-\(idx)"
    }
}
