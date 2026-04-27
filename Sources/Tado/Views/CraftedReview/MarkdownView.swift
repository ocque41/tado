import SwiftUI

/// Renders a single `MarkdownBlock` in the Tado review modal style.
/// Inline formatting (`**bold**`, `_italic_`, ``code``, `[link](url)`)
/// goes through SwiftUI's built-in `AttributedString(markdown:)` so we
/// don't reimplement an inline parser. Block-level chrome (heading
/// sizes, code-fence background, list bullet) is local to this file.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text, _):
            heading(level: level, text: text)
        case let .paragraph(text):
            Text(inline(text))
                .font(Typography.bodyLg)
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .list(items, ordered):
            listView(items: items, ordered: ordered)
        case let .code(text, lang):
            codeBlock(text: text, lang: lang)
        case .divider:
            Divider()
                .background(Palette.divider)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        let font: Font = {
            switch level {
            case 1: return Typography.display
            case 2: return Typography.displaySm
            case 3: return Typography.titleSm
            case 4: return Typography.headingLg
            case 5: return Typography.heading
            default: return Typography.headingSm
            }
        }()
        let topPad: CGFloat = level == 1 ? 0 : (level == 2 ? 16 : 8)
        Text(text)
            .font(font)
            .foregroundStyle(Palette.textPrimary)
            .padding(.top, topPad)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func listView(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(inline(item))
                        .font(Typography.bodyLg)
                        .foregroundStyle(Palette.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func codeBlock(text: String, lang: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lang.isEmpty {
                Text(lang.uppercased())
                    .font(Typography.microBold)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            Text(text)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, lang.isEmpty ? 10 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Best-effort inline parser. SwiftUI's `AttributedString(markdown:)`
    /// handles `**bold**`, `_italic_`, ``code``, `[link](url)`; if it
    /// fails (malformed input), we fall back to plain text rather than
    /// surfacing the parse error in the modal.
    private func inline(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: raw) {
            return parsed
        }
        return AttributedString(raw)
    }
}
