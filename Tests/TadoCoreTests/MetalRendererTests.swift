import XCTest
import Metal
@testable import Tado

/// Validates that the Metal renderer pipeline compiles end-to-end and
/// actually produces non-blank pixels when fed a synthetic snapshot.
///
/// These tests require a real Metal device, so they're skipped gracefully
/// when `MTLCreateSystemDefaultDevice()` returns nil (headless CI).
final class MetalRendererTests: XCTestCase {

    func testPipelineCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        // The renderer init loads the shader library and builds the
        // pipeline — any shader syntax error surfaces here.
        let renderer = try MetalTerminalRenderer(
            device: device,
            metrics: FontMetrics.defaultMono(size: 13, scale: 1),
            cols: 10,
            rows: 3
        )
        XCTAssertEqual(renderer.cols, 10)
        XCTAssertEqual(renderer.rows, 3)
    }

    func testRendersGlyphsOffscreen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, metrics: FontMetrics.defaultMono(size: 13, scale: 1), cols: 20, rows: 3)

        // Hand-crafted snapshot: first row says "HI" on cells 0–1, rest blank.
        let snapshot = syntheticSnapshot(cols: 20, rows: 3) { c, _ in
            switch c {
            case 0: return TadoCore.Cell(ch: UInt32("H".unicodeScalars.first!.value),
                                         fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            case 1: return TadoCore.Cell(ch: UInt32("I".unicodeScalars.first!.value),
                                         fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            default: return TadoCore.Cell(ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0)
            }
        }
        renderer.upload(snapshot: snapshot)

        let w = Int(renderer.metrics.cellWidth) * 20
        let h = Int(renderer.metrics.cellHeight) * 3
        guard let tex = renderer.renderOffscreen(width: w, height: h) else {
            XCTFail("renderOffscreen returned nil")
            return
        }

        // Read back BGRA bytes.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBufferPointer { buf in
            tex.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }

        // Count non-black pixels. With "HI" rendered in white, we expect
        // at least a few hundred pixels of ink in the first row.
        var litPixels = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]
            let g = pixels[i + 1]
            let r = pixels[i + 2]
            if r > 32 || g > 32 || b > 32 {
                litPixels += 1
            }
        }
        XCTAssertGreaterThan(litPixels, 50,
            "expected > 50 lit pixels from rendering 'HI', got \(litPixels)")
    }

    /// Regression test for the glyph lookup rebuild bug: for freshly
    /// rasterized ASCII chars, the GPU lookup buffer must be up to date
    /// before the first frame. Render 'M' (dense glyph) next to a space
    /// cell and assert the 'M' cell has materially more ink than the space.
    /// Before the fix, both would render as pure background → equal ink
    /// → test fails.
    func testFreshGlyphRendersInFirstFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, metrics: FontMetrics.defaultMono(size: 13, scale: 1), cols: 4, rows: 1)
        let snapshot = syntheticSnapshot(cols: 4, rows: 1) { c, _ in
            switch c {
            case 0: return TadoCore.Cell(ch: UInt32("M".unicodeScalars.first!.value),
                                         fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            default: return TadoCore.Cell(ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0)
            }
        }
        renderer.upload(snapshot: snapshot)

        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let w = cellW * 4
        let h = cellH
        guard let tex = renderer.renderOffscreen(width: w, height: h) else {
            XCTFail("renderOffscreen returned nil")
            return
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBufferPointer { buf in
            tex.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }

        func inkInCell(col: Int) -> Int {
            var count = 0
            for y in 0..<h {
                for x in (col * cellW)..<((col + 1) * cellW) {
                    let i = (y * w + x) * 4
                    let b = pixels[i]; let g = pixels[i + 1]; let r = pixels[i + 2]
                    if r > 32 || g > 32 || b > 32 { count += 1 }
                }
            }
            return count
        }
        let mInk = inkInCell(col: 0)
        let spaceInk = inkInCell(col: 1)
        XCTAssertGreaterThan(mInk, spaceInk + 30,
            "expected 'M' cell to have materially more ink than a space cell (got M=\(mInk), space=\(spaceInk)) — indicates the glyph lookup buffer is stale")
    }

    /// When the atlas fills up, subsequent allocations reset it and
    /// succeed — the shader sees a fresh set of glyphs via the next
    /// lookup rebuild. Before Phase 2.18 this path silently returned
    /// nil and the glyph rendered as background.
    func testAtlasResetsAndRefillsOnOverflow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        // Tiny atlas: 64 × 64 px fits ~few glyphs at 13pt. Rasterize
        // enough characters to force one reset.
        let metrics = FontMetrics.defaultMono()
        let atlas = try GlyphAtlas(device: device, metrics: metrics, atlasSize: 64)
        let beforeMod = atlas.modCount

        // Hammer with ASCII chars until we trip at least one reset —
        // modCount will advance past the simple per-insert monotonic
        // count. 200 glyphs >> what fits in 64×64.
        var gotSomeNonNil = false
        for ch: UInt32 in 33...232 {
            if atlas.uvRect(for: ch) != nil {
                gotSomeNonNil = true
            }
        }
        XCTAssertTrue(gotSomeNonNil, "no glyph ever rasterized")
        // modCount should have advanced (every inserted rect bumps it,
        // plus the reset itself bumps by 1).
        XCTAssertGreaterThan(atlas.modCount, beforeMod)
    }

    /// Phase 2.20 — emoji rasterizes via the BGRA color atlas and ends up
    /// with meaningfully-different R/G/B channels in the rendered frame.
    /// Before this phase, `CTFontDrawGlyphs` onto an R8 grayscale context
    /// produced a silhouette with R==G==B; after, the color atlas carries
    /// Apple Color Emoji's sbix pixels verbatim and the shader composites
    /// them without tinting.
    func testEmojiRendersInColor() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, metrics: FontMetrics.defaultMono(size: 13, scale: 1), cols: 2, rows: 1)
        // 🎉 party popper: multi-colored (red, yellow, blue) — reliable
        // channel-spread signal. Wide char (East-Asian Wide), so the
        // glyph actually fills both cells.
        let party: UInt32 = 0x1F389
        let snapshot = syntheticSnapshot(cols: 2, rows: 1) { c, _ in
            switch c {
            case 0:
                // Mark as wide; col 1 becomes the WIDE_FILLER skipped quad.
                return TadoCore.Cell(
                    ch: party,
                    fg: 0xFFFFFFFF,
                    bg: 0x000000FF,
                    attrs: MetalTerminalRenderer.Attr.wide
                )
            default:
                return TadoCore.Cell(
                    ch: 0,
                    fg: 0xE8E8E8FF,
                    bg: 0x000000FF,
                    attrs: MetalTerminalRenderer.Attr.wideFiller
                )
            }
        }
        renderer.upload(snapshot: snapshot)

        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let w = cellW * 2
        let h = cellH
        guard let tex = renderer.renderOffscreen(width: w, height: h) else {
            XCTFail("renderOffscreen returned nil")
            return
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBufferPointer { buf in
            tex.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }

        // Count pixels where the color channels diverge meaningfully.
        // Layout is BGRA — byte order B, G, R, A per pixel. A monochrome
        // emoji would have R == G == B for every lit pixel. A colored
        // emoji yields many pixels with a spread > 32 (the threshold is
        // chosen above AA softening but below visible differentiation).
        var colorfulPixels = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let r = Int(pixels[i + 2])
            let minChan = min(r, min(g, b))
            let maxChan = max(r, max(g, b))
            if maxChan - minChan > 32 {
                colorfulPixels += 1
            }
        }
        XCTAssertGreaterThan(
            colorfulPixels, 10,
            "expected 🎉 to render in color via the BGRA color atlas — got only \(colorfulPixels) pixels with channel spread > 32 (monochrome regression?)"
        )
    }

    /// Astral-plane codepoints (> U+FFFF) previously returned nil
    /// unconditionally. Phase 2.19 makes the atlas try a surrogate-pair
    /// + font-fallback rasterization path. The test hits two cases:
    ///   * U+1D400 (MATHEMATICAL BOLD CAPITAL A) — part of the
    ///     mathematical alphanumeric block; broadly supported by
    ///     system fonts on macOS.
    ///   * U+1F600 (GRINNING FACE) — emoji; Apple Color Emoji covers it.
    ///     Phase 2.20 rasterizes this into the color atlas; the test
    ///     still passes because `uvRect(for:)` returns non-nil for either
    ///     atlas.
    func testAstralCodepointsRasterize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let atlas = try GlyphAtlas(
            device: device,
            metrics: FontMetrics.defaultMono(),
            atlasSize: 512
        )
        let math = UInt32(0x1D400) // 𝐀
        let emoji = UInt32(0x1F600) // 😀
        XCTAssertNotNil(
            atlas.uvRect(for: math),
            "U+1D400 should rasterize via font fallback"
        )
        XCTAssertNotNil(
            atlas.uvRect(for: emoji),
            "U+1F600 (emoji) should rasterize monochrome via Apple Color Emoji"
        )
    }

    /// Regression for Phase 2.6.1's hidden bug: `CTFontCreateWithName("SF
    /// Mono", …, nil)` silently falls back to **Helvetica** — a proportional
    /// font — because the "SF Mono" string name isn't a public Core Text
    /// lookup key on current macOS. At 26 pt Helvetica 'W' advances 24.5 pt
    /// while 'I' advances 7.2 pt. Dropped into a 16-pixel atlas slot, the
    /// right half of 'W' is clipped — what remains reads as 'V' on screen
    /// (W→V, O→C, M→N from dogfood).
    ///
    /// Fix: `FontMetrics.defaultMono` now calls
    /// `NSFont.monospacedSystemFont(ofSize:weight:)` which returns
    /// `.AppleSystemUIFontMonospaced-Regular` — a true monospace. The test
    /// locks this in by asserting every ASCII letter + digit has an equal
    /// advance on the returned font AND on its raster-sized copy.
    func testDefaultMonoFontIsActuallyMonospace() throws {
        let metrics = FontMetrics.defaultMono(size: 13, scale: 2)

        func advances(for font: CTFont) -> [CGFloat] {
            let probe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            var chars: [UniChar] = probe.utf16.map { $0 }
            var glyphs: [CGGlyph] = Array(repeating: 0, count: chars.count)
            _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
            var result: [CGSize] = Array(repeating: .zero, count: chars.count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &result, chars.count)
            return result.map { $0.width }
        }

        // Logical font: all ASCII glyphs must share one advance. If they
        // don't, we landed on a proportional fallback again.
        let logicalAdvances = advances(for: metrics.font)
        let firstLogical = logicalAdvances[0]
        for (i, a) in logicalAdvances.enumerated() where abs(a - firstLogical) > 0.01 {
            XCTFail("logical font is not monospace — glyph \(i) advance=\(a) vs first=\(firstLogical)")
            return
        }

        // Raster font (2× scale): must also be monospace, with advances
        // equal to 2× the logical advance. If the raster copy ever picked
        // up a different family by accident, the mismatch would surface
        // here.
        let rasterAdvances = advances(for: metrics.rasterFont)
        let firstRaster = rasterAdvances[0]
        for (i, a) in rasterAdvances.enumerated() where abs(a - firstRaster) > 0.01 {
            XCTFail("raster font is not monospace — glyph \(i) advance=\(a) vs first=\(firstRaster)")
            return
        }
        XCTAssertEqual(
            firstRaster, firstLogical * 2, accuracy: 0.01,
            "raster font advance should be 2× logical (scale=2)"
        )
    }

    /// End-to-end check: at scale=2, each rendered ASCII cell contains a
    /// DISTINCT glyph signature — we should be able to tell 'O' from 'C',
    /// 'W' from 'V', 'M' from 'N' by comparing the rendered pixels of a
    /// cell directly against the rendered pixels of the other letter.
    ///
    /// Before the font fix, the raster font was Helvetica: 'W' at 26 pt
    /// wanted ~24 pixels but the 16-pixel bitmap slot clipped off the
    /// right half, leaving a shape visually identical to 'V'. This test
    /// would have shown near-zero pixel difference between the two.
    func testAsciiGlyphsAreDistinguishableAtRetinaScale() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }

        // scale=2 mirrors a Retina MTKView; this is the regime where the
        // Helvetica-fallback clipping bug was visible.
        let metrics = FontMetrics.defaultMono(size: 13, scale: 2)
        let pairs: [(Character, Character)] = [("W", "V"), ("O", "C"), ("M", "N")]

        func renderCell(_ ch: Character) throws -> [UInt8] {
            let renderer = try MetalTerminalRenderer(
                device: device, metrics: metrics, cols: 1, rows: 1
            )
            let snapshot = syntheticSnapshot(cols: 1, rows: 1) { _, _ in
                TadoCore.Cell(
                    ch: UInt32(ch.unicodeScalars.first!.value),
                    fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0
                )
            }
            renderer.upload(snapshot: snapshot)
            // Drawable pixels = logical cell × scale. Using integer
            // multiples keeps fragment/texel alignment exact.
            let w = Int(metrics.cellWidth * metrics.scale)
            let h = Int(metrics.cellHeight * metrics.scale)
            guard let tex = renderer.renderOffscreen(width: w, height: h) else {
                XCTFail("renderOffscreen returned nil for '\(ch)'")
                return []
            }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBufferPointer { buf in
                tex.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: w * 4,
                    from: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0
                )
            }
            return pixels
        }

        for (a, b) in pairs {
            let pa = try renderCell(a)
            let pb = try renderCell(b)
            XCTAssertEqual(pa.count, pb.count, "cell sizes must match")
            // Count pixels where the luminance differs meaningfully. With
            // the bug, 'W' got clipped to look like 'V' → few different
            // pixels. With the fix, the distinct shapes produce hundreds
            // of pixels of difference.
            var diffs = 0
            for i in stride(from: 0, to: pa.count, by: 4) {
                let la = Int(pa[i]) + Int(pa[i + 1]) + Int(pa[i + 2])
                let lb = Int(pb[i]) + Int(pb[i + 1]) + Int(pb[i + 2])
                if abs(la - lb) > 48 { diffs += 1 }
            }
            XCTAssertGreaterThan(
                diffs, 30,
                "'\(a)' and '\(b)' should be visually distinct at scale=2 — got only \(diffs) differing pixels (font fallback regression?)"
            )
        }
    }

    func testRendersLiveSessionSnapshot() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        // End-to-end: TadoCore PTY -> Metal renderer.
        guard let session = TadoCore.Session(
            command: "/bin/echo",
            args: ["abcd"],
            cwd: nil,
            environment: [:],
            cols: 10,
            rows: 2
        ) else {
            XCTFail("spawn returned nil")
            return
        }
        // Wait for echo output to land in the grid.
        let deadline = Date().addingTimeInterval(2.0)
        var snap: TadoCore.Snapshot?
        while Date() < deadline {
            if let s = session.snapshotFull() {
                let text = String(s.cells.prefix(10).compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("abcd") { snap = s; break }
            }
            usleep(50_000)
        }
        guard let snap else {
            XCTFail("never saw echo output")
            return
        }

        let renderer = try MetalTerminalRenderer(device: device, metrics: FontMetrics.defaultMono(size: 13, scale: 1), cols: 10, rows: 2)
        renderer.upload(snapshot: snap)

        let w = Int(renderer.metrics.cellWidth) * 10
        let h = Int(renderer.metrics.cellHeight) * 2
        XCTAssertNotNil(renderer.renderOffscreen(width: w, height: h))
    }

    // MARK: helpers

    /// Build a TadoCore.Snapshot by hand. Used to test the renderer without
    /// spinning up a PTY.
    private func syntheticSnapshot(
        cols: UInt16,
        rows: UInt16,
        fill: (Int, Int) -> TadoCore.Cell
    ) -> TadoCore.Snapshot {
        // We can't call the private `Snapshot.init` directly — it's guarded
        // by the Rust FFI. Instead, allocate a synthetic snapshot via the
        // same path used in production: spawn a /bin/sh that immediately
        // exits, so we get a valid (empty) Snapshot object we can overlay.
        //
        // Simpler: expose a factory. See TadoCore+Testing.swift.
        return TadoCore.Snapshot.synthetic(cols: cols, rows: rows, fill: fill)
    }
}
