import CoreGraphics
import CoreText
import Foundation
import Metal

/// Dual glyph cache:
///   * `texture`       — monochrome R8 atlas for text (default 4096²).
///   * `colorTexture`  — BGRA8 color atlas for glyphs whose resolved font
///                       is a color font (Apple Color Emoji on macOS).
///                       Default 2048² since RGBA is 4× mono memory per
///                       pixel; half the side gives roughly equal bytes.
///
/// Each atlas has its own shelf allocator + UV rect table. `uvRect(for:)`
/// returns whichever atlas now owns the glyph; `isColorGlyph(_:)` lets the
/// renderer decide which texture to sample (see `ATTR_COLOR_GLYPH` in
/// `MetalTerminalRenderer.Attr`). Both atlases share a single `modCount`
/// so the renderer rebuilds its GPU lookup buffer on any insertion.
///
/// Notes carried forward from the R8-only era:
/// - Blank cells (ch == 0 or space) map to a zero-area rect; the shader
///   short-circuits to pure background.
/// - No LRU. At 4096² R8 the atlas holds ~16k 10×16 glyphs; at 2048²
///   RGBA ~4k color glyphs. Overflow triggers a one-shot reset of both
///   atlases, which bumps modCount so the renderer rebuilds its lookup.
final class GlyphAtlas {
    let device: MTLDevice
    let texture: MTLTexture        // mono, R8
    let colorTexture: MTLTexture   // color, BGRA8
    let metrics: FontMetrics
    let atlasSize: Int
    let colorAtlasSize: Int

    // Mono shelf state.
    private var shelfY: Int = 0
    private var shelfX: Int = 0
    private var shelfHeight: Int = 0
    private var rects: [UInt32: CGRect] = [:]

    // Color shelf state.
    private var colorShelfY: Int = 0
    private var colorShelfX: Int = 0
    private var colorShelfHeight: Int = 0
    private var colorRects: [UInt32: CGRect] = [:]

    /// Monotonic counter incremented on every successful (non-empty) rect
    /// insertion in either atlas. Renderers compare against their last-built
    /// modCount to decide whether the GPU lookup buffer needs rebuilding.
    private(set) var modCount: Int = 0

    /// Glyphs with no visible ink (space, NBSP, control codes) — mapped to a
    /// zero rect so the shader doesn't sample the atlas for them.
    static let emptyRect = CGRect.zero

    init(
        device: MTLDevice,
        metrics: FontMetrics,
        atlasSize: Int = 4096,
        colorAtlasSize: Int = 2048
    ) throws {
        self.device = device
        self.metrics = metrics
        self.atlasSize = atlasSize
        self.colorAtlasSize = colorAtlasSize

        // Mono atlas — R8, grayscale coverage.
        let monoDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        monoDesc.usage = [.shaderRead]
        monoDesc.storageMode = .shared
        guard let monoTex = device.makeTexture(descriptor: monoDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.texture = monoTex

        // Color atlas — BGRA8, holds pre-multiplied RGBA pixels rasterized
        // from color fonts. The renderer samples from this atlas when the
        // cell carries ATTR_COLOR_GLYPH and composites directly (no tint).
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: colorAtlasSize,
            height: colorAtlasSize,
            mipmapped: false
        )
        colorDesc.usage = [.shaderRead]
        colorDesc.storageMode = .shared
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.colorTexture = colorTex

        // Reserve index 0 as the "blank" / empty-rect slot so `cell.ch == 0`
        // renders as pure background without a sampler read.
        rects[0] = GlyphAtlas.emptyRect
        rects[UInt32(" ".unicodeScalars.first!.value)] = GlyphAtlas.emptyRect
    }

    /// True when `ch` has been rasterized into the color atlas (i.e. its
    /// resolved font is a color font — Apple Color Emoji on macOS). The
    /// renderer uses this to tag `CellInstance.attrs` with `ATTR_COLOR_GLYPH`
    /// before upload so the shader knows which atlas to sample. False for
    /// mono glyphs, unrasterized codepoints, or empty/blank cells.
    func isColorGlyph(_ ch: UInt32) -> Bool {
        if let rect = colorRects[ch], !rect.isEmpty {
            return true
        }
        return false
    }

    /// Throw away every cached glyph in both atlases and rewind the shelf
    /// allocators. Called when `allocateRect(...)` can't fit a new glyph at
    /// the current shelf position. Bumps `modCount` so renderers know their
    /// GPU-side lookup table is stale and needs a rebuild. The underlying
    /// MTLTextures are NOT cleared — stale pixels linger until overwritten,
    /// but UV rects never point at them because all rect entries are
    /// discarded. The blank/space reservations are reinserted so `ch == 0` /
    /// `ch == 32` still short-circuit.
    func reset() {
        rects.removeAll(keepingCapacity: true)
        rects[0] = GlyphAtlas.emptyRect
        rects[UInt32(" ".unicodeScalars.first!.value)] = GlyphAtlas.emptyRect
        shelfX = 0
        shelfY = 0
        shelfHeight = 0

        colorRects.removeAll(keepingCapacity: true)
        colorShelfX = 0
        colorShelfY = 0
        colorShelfHeight = 0

        modCount &+= 1
    }

    /// UV rect for `ch` in 0..1 of whichever atlas now owns the glyph. Nil
    /// means "no glyph" — caller should render pure background. Allocates
    /// into the atlas on first request. `cellSpan` hints whether this
    /// codepoint occupies two terminal cells (2) or one (1). Wide glyphs
    /// get a 2× cellWidth bitmap so CJK / wide box-drawing renders at
    /// natural proportions.
    func uvRect(for ch: UInt32, cellSpan: Int = 1) -> CGRect? {
        return allocateRect(for: ch, cellSpan: cellSpan, allowReset: true)
    }

    private func allocateRect(
        for ch: UInt32,
        cellSpan: Int,
        allowReset: Bool
    ) -> CGRect? {
        // Cache: check both atlases first.
        if let cached = rects[ch] {
            return cached.isEmpty ? nil : cached
        }
        if let cached = colorRects[ch] {
            return cached.isEmpty ? nil : cached
        }

        guard let scalar = Unicode.Scalar(ch),
              !scalar.properties.isDefaultIgnorableCodePoint else {
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        // Rasterize — returns either .mono or .color depending on the
        // resolved font. We don't know which atlas to pack into until
        // font fallback has chosen the font.
        guard let rasterized = rasterize(
            scalar: scalar,
            cellSpan: max(1, cellSpan)
        ) else {
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        switch rasterized {
        case .mono(let pixelRect, let pixels):
            return packMono(
                ch: ch,
                pixelRect: pixelRect,
                pixels: pixels,
                cellSpan: cellSpan,
                allowReset: allowReset
            )
        case .color(let pixelRect, let pixels):
            return packColor(
                ch: ch,
                pixelRect: pixelRect,
                pixels: pixels,
                cellSpan: cellSpan,
                allowReset: allowReset
            )
        }
    }

    private func packMono(
        ch: UInt32,
        pixelRect: CGRect,
        pixels: [UInt8],
        cellSpan: Int,
        allowReset: Bool
    ) -> CGRect? {
        let w = Int(pixelRect.width)
        let h = Int(pixelRect.height)
        if w <= 0 || h <= 0 {
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }
        if shelfX + w > atlasSize {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + h > atlasSize {
            if allowReset {
                reset()
                return allocateRect(for: ch, cellSpan: cellSpan, allowReset: false)
            }
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        let region = MTLRegionMake2D(shelfX, shelfY, w, h)
        pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: w
            )
        }

        let uv = CGRect(
            x: CGFloat(shelfX) / CGFloat(atlasSize),
            y: CGFloat(shelfY) / CGFloat(atlasSize),
            width: CGFloat(w) / CGFloat(atlasSize),
            height: CGFloat(h) / CGFloat(atlasSize)
        )
        rects[ch] = uv
        modCount &+= 1

        shelfX += w
        shelfHeight = max(shelfHeight, h)

        return uv
    }

    private func packColor(
        ch: UInt32,
        pixelRect: CGRect,
        pixels: [UInt8],
        cellSpan: Int,
        allowReset: Bool
    ) -> CGRect? {
        let w = Int(pixelRect.width)
        let h = Int(pixelRect.height)
        if w <= 0 || h <= 0 {
            colorRects[ch] = GlyphAtlas.emptyRect
            return nil
        }
        if colorShelfX + w > colorAtlasSize {
            colorShelfY += colorShelfHeight
            colorShelfX = 0
            colorShelfHeight = 0
        }
        if colorShelfY + h > colorAtlasSize {
            if allowReset {
                reset()
                return allocateRect(for: ch, cellSpan: cellSpan, allowReset: false)
            }
            colorRects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        let region = MTLRegionMake2D(colorShelfX, colorShelfY, w, h)
        pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            colorTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: w * 4  // BGRA
            )
        }

        let uv = CGRect(
            x: CGFloat(colorShelfX) / CGFloat(colorAtlasSize),
            y: CGFloat(colorShelfY) / CGFloat(colorAtlasSize),
            width: CGFloat(w) / CGFloat(colorAtlasSize),
            height: CGFloat(h) / CGFloat(colorAtlasSize)
        )
        colorRects[ch] = uv
        modCount &+= 1

        colorShelfX += w
        colorShelfHeight = max(colorShelfHeight, h)

        return uv
    }

    private enum RasterResult {
        case mono(CGRect, [UInt8])   // R8 bytes, length = w*h
        case color(CGRect, [UInt8])  // BGRA bytes, length = w*h*4
    }

    /// Rasterize a single glyph with CoreText, returning whichever pixel
    /// format fits the resolved font. Color fonts (Apple Color Emoji)
    /// take the BGRA path; everything else is R8.
    /// Supports astral codepoints via surrogate-pair encoding with font
    /// fallback.
    private func rasterize(
        scalar: Unicode.Scalar,
        cellSpan: Int = 1
    ) -> RasterResult? {
        // Encode as UTF-16 so CoreText handles both BMP and astral
        // codepoints through one code path.
        let chars = Array(String(scalar).utf16)
        guard !chars.isEmpty else { return nil }

        // Try the configured (scaled) raster font first. If it has no
        // glyph (common for emoji / CJK), ask CoreText for a fallback
        // that does — CTFontCreateForString preserves the raster font's
        // size so the fallback also rasterizes at the right pixel scale.
        var activeFont = metrics.rasterFont
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = chars.withUnsafeBufferPointer { charBuf in
            glyphs.withUnsafeMutableBufferPointer { glyphBuf in
                CTFontGetGlyphsForCharacters(
                    activeFont, charBuf.baseAddress!, glyphBuf.baseAddress!, chars.count
                )
            }
        }
        if glyphs[0] == 0 {
            let cfStr = String(scalar) as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(cfStr))
            activeFont = CTFontCreateForString(metrics.rasterFont, cfStr, range)
            _ = chars.withUnsafeBufferPointer { charBuf in
                glyphs.withUnsafeMutableBufferPointer { glyphBuf in
                    CTFontGetGlyphsForCharacters(
                        activeFont, charBuf.baseAddress!, glyphBuf.baseAddress!, chars.count
                    )
                }
            }
        }
        guard glyphs[0] != 0 else { return nil }
        let glyph = glyphs[0]

        // Bitmap dims in PIXELS — cellWidth/cellHeight scaled by the
        // backing factor so Retina glyphs fill a 2× dense cell.
        let w = metrics.rasterCellWidth * max(1, cellSpan)
        let h = metrics.rasterCellHeight
        guard w > 0, h > 0 else { return nil }

        if isColorFont(activeFont) {
            return rasterizeColor(glyph: glyph, font: activeFont, w: w, h: h)
        }
        return rasterizeMono(glyph: glyph, font: activeFont, w: w, h: h)
    }

    /// True when the font carries author-authored color glyphs (sbix /
    /// COLR / CBDT). Core Text exposes this as the `colorGlyphs` symbolic
    /// trait, so we read the trait bit directly rather than string-matching
    /// on family names. A string match works for "Apple Color Emoji" but
    /// misses the UI variant `.Apple Color Emoji UI` that Core Text routes
    /// to when the base font is `monospacedSystemFont` — the switch to
    /// that API in Phase 2.6.2 surfaced this.
    private func isColorFont(_ font: CTFont) -> Bool {
        CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
    }

    /// R8 path — white ink, grayscale coverage. Unchanged from the
    /// pre-dual-atlas era.
    private func rasterizeMono(
        glyph: CGGlyph,
        font: CTFont,
        w: Int,
        h: Int
    ) -> RasterResult? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = pixels.withUnsafeMutableBufferPointer({ buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else {
            return nil
        }

        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        // White ink on a cleared (black) bitmap — R channel doubles as
        // glyph coverage in the R8 atlas.
        ctx.setFillColor(
            CGColor(colorSpace: colorSpace, components: [1.0, 1.0])
                ?? .init(gray: 1.0, alpha: 1.0)
        )

        var position = CGPoint(x: 0, y: CGFloat(h) - metrics.rasterBaseline)
        var g = glyph
        CTFontDrawGlyphs(font, &g, &position, 1, ctx)

        return .mono(CGRect(x: 0, y: 0, width: w, height: h), pixels)
    }

    /// BGRA8 premultiplied path — color fonts carry their own pixel colors
    /// via embedded bitmaps (sbix on Apple Color Emoji). The fragment
    /// shader composites directly (no tint) so the emoji renders in its
    /// author-intended colors.
    private func rasterizeColor(
        glyph: CGGlyph,
        font: CTFont,
        w: Int,
        h: Int
    ) -> RasterResult? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Premultiplied-first + byteOrder32Little = BGRA pixel layout,
        // matching the MTLPixelFormat.bgra8Unorm color atlas and Metal's
        // texture read convention.
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = pixels.withUnsafeMutableBufferPointer({ buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }) else {
            return nil
        }

        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        // No fill color set — CTFontDrawGlyphs on a color font copies
        // the author-authored bitmap/sbix pixels verbatim.

        var position = CGPoint(x: 0, y: CGFloat(h) - metrics.rasterBaseline)
        var g = glyph
        CTFontDrawGlyphs(font, &g, &position, 1, ctx)

        return .color(CGRect(x: 0, y: 0, width: w, height: h), pixels)
    }

    /// Copy the current `slot -> GlyphRect(u0,v0,u1,v1)` table into a
    /// Metal buffer sized `maxCodepoint + 1`. For BMP slots (< 0x10000)
    /// the "slot" is the Unicode codepoint itself. For astral slots
    /// (>= 0x10000), `slotMap[slot]` gives the real astral codepoint
    /// whose UV rect to write. The UV rect comes from whichever atlas
    /// owns the glyph — color rects first, then mono, so color takes
    /// precedence if somehow both are populated.
    func buildLookupBuffer(
        device: MTLDevice,
        maxCodepoint: UInt32 = 0x80,
        slotMap: [UInt32: UInt32]? = nil
    ) -> MTLBuffer? {
        let count = Int(maxCodepoint) + 1
        let stride = MemoryLayout<SIMD4<Float>>.stride
        guard let buffer = device.makeBuffer(
            length: stride * count,
            options: .storageModeShared
        ) else {
            return nil
        }
        let ptr = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        for i in 0..<count {
            let key: UInt32
            if UInt32(i) < 0x10000 {
                key = UInt32(i)
            } else if let mapped = slotMap?[UInt32(i)] {
                key = mapped
            } else {
                ptr[i] = SIMD4<Float>(0, 0, 0, 0)
                continue
            }
            if let rect = colorRects[key], !rect.isEmpty {
                ptr[i] = SIMD4<Float>(
                    Float(rect.minX), Float(rect.minY),
                    Float(rect.maxX), Float(rect.maxY)
                )
            } else if let rect = rects[key], !rect.isEmpty {
                ptr[i] = SIMD4<Float>(
                    Float(rect.minX), Float(rect.minY),
                    Float(rect.maxX), Float(rect.maxY)
                )
            } else {
                ptr[i] = SIMD4<Float>(0, 0, 0, 0)
            }
        }
        return buffer
    }
}

enum RendererError: Error {
    case deviceUnavailable
    case commandQueueCreationFailed
    case textureCreationFailed
    case libraryCreationFailed
    case pipelineCreationFailed
}
