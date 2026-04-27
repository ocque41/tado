import SwiftUI

/// Left sidebar of the crafted.md review modal — a clickable list of
/// the document's level-2 headings. Clicking a row asks the body to
/// scroll to that heading via the bound `selectedSlug` plus an
/// `onSelect` callback (the modal owns the `ScrollViewReader`).
struct CraftedReviewIndex: View {
    let sections: [(text: String, slug: String)]
    @Binding var selectedSlug: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONTENTS")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if sections.isEmpty {
                        Text("No sections")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
                            row(index: idx + 1, section: section)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Palette.surfaceElevated)
    }

    @ViewBuilder
    private func row(index: Int, section: (text: String, slug: String)) -> some View {
        let isSelected = selectedSlug == section.slug
        Button(action: { onSelect(section.slug) }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(Typography.monoCaption)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(section.text)
                    .font(Typography.body)
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Palette.surfaceAccent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
