import CoreGraphics
import CoreText
import Foundation
import Metal

/// Lazy glyph cache backed by a single `MTLTexture` (R8, 2048×2048 by default).
///
/// API: `uvRect(for: ch)` returns a `CGRect` in 0..1 UV space. On a miss,
/// the glyph is rasterized with CoreText and packed into the atlas via a
/// shelf allocator (simple, good-enough for monospace — every glyph the
/// same height, so rows never waste vertical space).
///
/// Phase 2.1 scope:
/// - ASCII + Latin-1 supplementary covered by lazy insertion
/// - Blank cells (ch == 0 or space) map to a zero-area rect; the shader
///   short-circuits to pure background
/// - No LRU eviction yet. At 2048² R8 the atlas holds ~16k 10×16 glyphs,
///   more than enough for Phase 2. LRU lands with CJK support in Phase 3.
final class GlyphAtlas {
    let device: MTLDevice
    let texture: MTLTexture
    let metrics: FontMetrics
    let atlasSize: Int

    private var shelfY: Int = 0
    private var shelfX: Int = 0
    private var shelfHeight: Int = 0
    private var rects: [UInt32: CGRect] = [:] // char -> UV rect

    /// Monotonic counter incremented on every successful (non-empty) rect
    /// insertion. Renderers compare against their last-built modCount to
    /// decide whether the GPU lookup buffer needs rebuilding. Cheap
    /// approximation of a proper "dirty chars since last build" set.
    private(set) var modCount: Int = 0

    /// Glyphs with no visible ink (space, NBSP, control codes) — mapped to a
    /// zero rect so the shader doesn't sample the atlas for them.
    static let emptyRect = CGRect.zero

    init(device: MTLDevice, metrics: FontMetrics, atlasSize: Int = 2048) throws {
        self.device = device
        self.metrics = metrics
        self.atlasSize = atlasSize

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw RendererError.textureCreationFailed
        }
        self.texture = tex

        // Reserve index 0 as the "blank" / empty-rect slot so `cell.ch == 0`
        // renders as pure background without a sampler read.
        rects[0] = GlyphAtlas.emptyRect
        rects[UInt32(" ".unicodeScalars.first!.value)] = GlyphAtlas.emptyRect
    }

    /// UV rect for `ch` in 0..1. Nil means "no glyph" — caller (shader)
    /// should render pure background. Allocates into the atlas on first
    /// request for a given char.
    func uvRect(for ch: UInt32) -> CGRect? {
        if let cached = rects[ch] {
            return cached.isEmpty ? nil : cached
        }
        guard let scalar = Unicode.Scalar(ch), !scalar.properties.isDefaultIgnorableCodePoint else {
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        // Rasterize.
        guard let (pixelRect, pixels) = rasterize(scalar: scalar) else {
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        // Shelf-pack.
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
            // Atlas full. Return nil — callers fall back to bg. Phase 3
            // replaces this with LRU eviction.
            rects[ch] = GlyphAtlas.emptyRect
            return nil
        }

        // Upload pixels.
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

        // UV rect in 0..1.
        let uv = CGRect(
            x: CGFloat(shelfX) / CGFloat(atlasSize),
            y: CGFloat(shelfY) / CGFloat(atlasSize),
            width: CGFloat(w) / CGFloat(atlasSize),
            height: CGFloat(h) / CGFloat(atlasSize)
        )
        rects[ch] = uv
        modCount &+= 1 // wrap-safe; renderer just checks != for inequality

        shelfX += w
        shelfHeight = max(shelfHeight, h)

        return uv
    }

    /// Rasterize a single glyph into an R8 pixel buffer with CoreText.
    /// Returns (pixelRect, pixels) where pixelRect.size is the glyph's
    /// bounding rect in pixels and pixels.count == width*height.
    private func rasterize(scalar: Unicode.Scalar) -> (CGRect, [UInt8])? {
        var ch: UniChar = UInt16(clamping: scalar.value)
        var glyph: CGGlyph = 0
        if scalar.value > 0xFFFF {
            // Surrogate pair — skip for Phase 2.1. Phase 3 handles emoji.
            return nil
        }
        let ok = CTFontGetGlyphsForCharacters(metrics.font, &ch, &glyph, 1)
        guard ok, glyph != 0 else { return nil }

        // Cell-sized bitmap so baseline positioning is consistent per row.
        let w = Int(metrics.cellWidth)
        let h = Int(metrics.cellHeight)
        guard w > 0, h > 0 else { return nil }

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
        // White ink on a cleared (black) bitmap — the R channel doubles as
        // glyph coverage for the R8 atlas.
        ctx.setFillColor(
            CGColor(colorSpace: colorSpace, components: [1.0, 1.0]) ?? .init(gray: 1.0, alpha: 1.0)
        )

        // CoreText y-origin is at baseline, pointing up. Our atlas is top-left
        // origin. Flip so baseline lands at `cellHeight - metrics.baseline`
        // pixels from the top.
        var position = CGPoint(
            x: 0,
            y: CGFloat(h) - metrics.baseline
        )
        var g = glyph
        CTFontDrawGlyphs(metrics.font, &g, &position, 1, ctx)

        return (CGRect(x: 0, y: 0, width: w, height: h), pixels)
    }

    /// Copy the current `ch -> GlyphRect(u0,v0,u1,v1)` table into a Metal
    /// buffer sized `maxCodepoint + 1`. Cheap enough to regenerate every
    /// few frames; for Phase 2 we rebuild it lazily when new glyphs get
    /// rasterized.
    func buildLookupBuffer(device: MTLDevice, maxCodepoint: UInt32 = 0x80) -> MTLBuffer? {
        let count = Int(maxCodepoint) + 1
        let stride = MemoryLayout<SIMD4<Float>>.stride
        guard let buffer = device.makeBuffer(length: stride * count, options: .storageModeShared) else {
            return nil
        }
        let ptr = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        for i in 0..<count {
            if let rect = rects[UInt32(i)], !rect.isEmpty {
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
