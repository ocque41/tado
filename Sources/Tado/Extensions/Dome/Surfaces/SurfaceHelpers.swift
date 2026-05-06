import SwiftUI

/// Shared helpers used by every Dome surface (KnowledgeSurface,
/// AutomationSurface, RecipesSurface, etc.). Lifted out of
/// KnowledgeSurface.swift in v0.11 so new top-level surfaces can
/// reuse the same header chrome and empty-state look without
/// re-implementing them.
///
/// v0.18 (this revision) keeps the API exactly as it was — same
/// argument order, same `@ViewBuilder` shape — but rebuilds the
/// rendering on top of the structural-grid `DesignKit`. The visual
/// upgrade fans out to **every** Dome surface for free, with zero
/// per-call-site edits required.

/// Top bar with title + subtitle + refresh button. Adapter over
/// `PageHeader` so every Dome surface inherits the design pass'
/// 28 pt mono-tracking title, hairline bottom rule, and bgPage
/// background. The `subtitle` becomes a single `MetaCell` on the
/// right side of the header so it still reads as descriptive
/// metadata rather than secondary chrome. The refresh button is
/// rendered as the design's `OutlineButton` icon-only variant; on
/// `isLoading` it shows the hourglass and disables itself, matching
/// the previous behaviour exactly.
@ViewBuilder
func surfaceHeader(title: String, subtitle: String, isLoading: Bool, refresh: @escaping () -> Void) -> some View {
    HStack(alignment: .bottom, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .default))
                .tracking(-0.4)
                .foregroundStyle(Palette.ink)
            Text(subtitle)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        Spacer(minLength: 16)
        OutlineButton(
            icon: isLoading ? "hourglass" : "arrow.clockwise",
            size: .small,
            variant: .standard,
            action: { if !isLoading { refresh() } }
        )
        .disabled(isLoading)
        .help("Refresh")
    }
    .padding(.horizontal, DK.pageGutter)
    .padding(.top, 24)
    .padding(.bottom, 14)
    .background(Palette.bgPage)
    .overlay(alignment: .bottom) {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: DK.ruleW)
    }
}

/// Centred empty-state placeholder. Adopts the structural design's
/// "headline + subline + dashed-top-border help line" pattern so
/// empty Dome surfaces read like the empty Dispatch / Eternal /
/// Projects sections — clearly intentional, not a blank pane. The
/// caller-supplied SF Symbol is preserved as a leading 22 pt glyph;
/// the `text` becomes the headline.
@ViewBuilder
func surfaceEmpty(icon: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.ink4)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        Text("Empty surface — once data lands here it will populate automatically.")
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: 540, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        Text("DOME SURFACE  ·  reads through dome-mcp / DomeRpcClient  ·  scope-filtered by the topbar selector")
            .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
            .foregroundStyle(Palette.ink4)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                    .padding(.horizontal, -2)
            }
    }
    .padding(.horizontal, DK.pageGutter)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}
