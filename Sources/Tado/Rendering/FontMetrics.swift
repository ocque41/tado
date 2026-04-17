import AppKit
import CoreText
import Foundation

/// Fixed-pitch font metrics for terminal cell sizing.
///
/// All public fields are **logical (point-space)** measurements. Use the
/// `raster*` accessors when sizing the glyph atlas bitmap — they multiply
/// by `scale` so Retina backing stores hold 2×-dense pixels without the
/// shader having to convert. Logical values are what SwiftUI / cols-math
/// consumes; raster values are what Core Text draws into.
///
/// Call `FontMetrics.defaultMono(size:scale:)` once per font+size+scale
/// change. Keep cells aligned to integer pixels — sub-pixel cell
/// boundaries make the glyph atlas sampler blur text unacceptably.
struct FontMetrics {
    /// Logical font at the requested point size. Used for measurement
    /// + fallback resolution (`CTFontCreateForString`).
    let font: CTFont
    /// Scaled-up copy of `font` at `size × scale`. Used when drawing
    /// into the atlas bitmap so retina backing stores get crisp
    /// pixel-perfect glyphs. Falls back to `font` when `scale == 1`.
    let rasterFont: CTFont
    /// Logical width of one monospace cell in points. Computed from a
    /// digit glyph's advance — more reliable than `advance.x` on
    /// variable-width fallbacks.
    let cellWidth: CGFloat
    /// Logical height of one cell in points — `ascent + descent + leading`.
    let cellHeight: CGFloat
    /// Logical baseline offset from the top of the cell in points.
    let baseline: CGFloat
    /// Backing-scale factor (1 on standard displays, 2 on Retina, 3 on
    /// some newer panels). When > 1, the atlas rasterizes at this
    /// multiplier so sampler output matches drawable pixel density.
    let scale: CGFloat

    /// Pixel width of a cell in the atlas bitmap (`cellWidth × scale`,
    /// rounded up to preserve integer pixel alignment).
    var rasterCellWidth: Int { Int(ceil(cellWidth * scale)) }
    /// Pixel height of a cell in the atlas bitmap.
    var rasterCellHeight: Int { Int(ceil(cellHeight * scale)) }
    /// Pixel baseline inside the atlas bitmap, measured from the top.
    var rasterBaseline: CGFloat { baseline * scale }

    init(font: CTFont, scale: CGFloat = 1) {
        self.font = font
        self.scale = max(1, scale)

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

        if self.scale == 1 {
            self.rasterFont = font
        } else {
            let scaledSize = CTFontGetSize(font) * self.scale
            self.rasterFont = CTFontCreateCopyWithAttributes(
                font, scaledSize, nil, nil
            )
        }
    }

    /// Default system monospaced font at the given point size.
    ///
    /// Uses `NSFont.monospacedSystemFont(ofSize:weight:)` — the only
    /// reliable way to get SF Mono on current macOS. The string-name
    /// lookup (`CTFontCreateWithName("SF Mono", …)`) silently falls
    /// back to Helvetica, which is proportional: 'W' advances 24.5 pt
    /// at 26 pt while 'I' advances 7.2 pt. That mismatch caused
    /// wide-glyph clipping (W→V, O→C, M→N) and uneven inter-character
    /// spacing in Metal tiles until this path switched APIs.
    ///
    /// When `scale` is left nil the initializer reads the main
    /// screen's backing factor (Retina = 2, non-Retina = 1) so tiles
    /// pick up pixel-dense rasterization automatically. Callers with
    /// a specific target — tests, off-screen renders, a different
    /// screen — can pass an explicit scale.
    static func defaultMono(size: CGFloat = 13, scale: CGFloat? = nil) -> FontMetrics {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let resolved = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        return FontMetrics(font: font, scale: resolved)
    }
}
