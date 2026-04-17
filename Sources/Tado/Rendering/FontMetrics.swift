import CoreText
import Foundation

/// Fixed-pitch font metrics for terminal cell sizing.
///
/// Call `FontMetrics(font:)` once per font+size change. Keep cells aligned
/// to integer pixels — sub-pixel cell boundaries make the glyph atlas
/// sampler blur text unacceptably.
struct FontMetrics {
    let font: CTFont
    /// Width of one monospace cell in pixels. Computed from a digit glyph's
    /// advance — more reliable than `advance.x` on variable-width fallbacks.
    let cellWidth: CGFloat
    /// Height of one cell in pixels — `ascent + descent + leading`, rounded up.
    let cellHeight: CGFloat
    /// Baseline offset from the top of the cell in pixels. Used when
    /// rasterizing glyphs into the atlas.
    let baseline: CGFloat

    init(font: CTFont) {
        self.font = font

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        // Measure a representative monospace glyph. Falls back to the font's
        // max advance if the digit glyph is missing (rare).
        var chars: [UniChar] = [UInt16(UnicodeScalar("0").value)]
        var glyphs: [CGGlyph] = [0]
        let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance: CGFloat = 0
        if ok, glyphs[0] != 0 {
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &adv, 1)
            advance = adv.width
        }
        if advance <= 0 {
            advance = CGFloat(CTFontGetSize(font)) * 0.6
        }

        self.cellWidth = ceil(advance)
        self.cellHeight = ceil(ascent + descent + leading)
        self.baseline = ceil(ascent)
    }

    /// Default SF Mono 13pt with Menlo fallback. Matches
    /// `TerminalNSViewRepresentable` today so tiles render at the same size.
    static func defaultMono(size: CGFloat = 13) -> FontMetrics {
        let font = CTFontCreateWithName("SF Mono" as CFString, size, nil)
        return FontMetrics(font: font)
    }
}
