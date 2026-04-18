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

    /// Regression for Phase 2.6.3's "zoom out in canvas zooms in the
    /// terminal + clips the right side of wide banners" bug.
    ///
    /// Root cause: `MTKView.autoResizeDrawable = true` derives drawable
    /// pixels from `bounds × layer.contentsScale`. SwiftUI's `scaleEffect`
    /// can nudge `contentsScale` on an NSViewRepresentable-wrapped
    /// NSView, so at canvas zoom=0.5 the drawable ended up 1× backing
    /// instead of 2×. The shader kept rendering cells at 16-raster-pixel
    /// cells but only half of them fit → visible clipping, and each cell
    /// occupied twice the fraction of the visible area → visual "zoom
    /// in". The fix reads the window's real `backingScaleFactor` (not
    /// contentsScale) and sets `drawableSize` explicitly.
    ///
    /// This test locks the pure math: across a range of bounds and
    /// backing factors typical of the field (1.0 non-Retina, 2.0
    /// Retina), the drawable must always be `bounds × backing`. If a
    /// future refactor re-introduces a contentsScale lookup, the math
    /// would drift and this test would fail.
    func testDrawablePixelSizeMatchesBoundsTimesBacking() {
        let cases: [(CGSize, CGFloat)] = [
            (CGSize(width: 660, height: 440), 2.0),
            (CGSize(width: 660, height: 440), 1.0),
            (CGSize(width: 330, height: 220), 2.0),   // canvas zoom=0.5 logical
            (CGSize(width: 1320, height: 880), 2.0),  // wide tile, Retina
            (CGSize(width: 1, height: 1), 2.0),
            (CGSize(width: 0, height: 0), 2.0),       // zero-bounds guard
        ]
        for (bounds, scale) in cases {
            let out = TerminalMTKView.drawablePixelSize(bounds: bounds, backingScale: scale)
            let expectW = max(1, Int(round(bounds.width * scale)))
            let expectH = max(1, Int(round(bounds.height * scale)))
            XCTAssertEqual(
                Int(out.width), expectW,
                "drawable width for bounds=\(bounds) scale=\(scale): expected \(expectW), got \(Int(out.width))"
            )
            XCTAssertEqual(
                Int(out.height), expectH,
                "drawable height for bounds=\(bounds) scale=\(scale): expected \(expectH), got \(Int(out.height))"
            )
        }
    }

    /// The grid must fill the drawable horizontally without overflowing:
    /// `cols × cellSizePixels ≤ drawable.width`. If this invariant
    /// breaks, shader-space cells spill past the right edge and produce
    /// exactly the visible clipping symptom the user reported.
    func testGridFitsInsideDrawableAtRetinaScale() {
        let metrics = FontMetrics.defaultMono(size: 13, scale: 2)
        let bounds = CGSize(width: 660, height: 440)
        let (cols, rows) = TerminalMTKView.gridSizeForBounds(bounds, metrics: metrics)
        let drawable = TerminalMTKView.drawablePixelSize(bounds: bounds, backingScale: 2)

        // cellSize in raster pixels — matches `MetalTerminalRenderer.encode`.
        let cellW = metrics.cellWidth * metrics.scale
        let cellH = metrics.cellHeight * metrics.scale

        XCTAssertLessThanOrEqual(
            CGFloat(cols) * cellW, drawable.width,
            "grid width \(Int(cols))×\(Int(cellW)) exceeds drawable \(Int(drawable.width)) — right-side clipping regression"
        )
        XCTAssertLessThanOrEqual(
            CGFloat(rows) * cellH, drawable.height,
            "grid height \(Int(rows))×\(Int(cellH)) exceeds drawable \(Int(drawable.height)) — bottom-edge clipping regression"
        )
        // Waste less than two full cells on each axis — a big gap
        // between "grid width" and "drawable width" would mean we're
        // losing usable cols and the Claude banner would wrap shorter
        // than it should.
        XCTAssertLessThan(
            drawable.width - CGFloat(cols) * cellW, 2 * cellW,
            "too much horizontal letterbox — cols math drifted"
        )
    }

    /// `FontMetrics.font(named:)` must: (a) accept an empty string as
    /// "system mono", (b) reject a bogus name and fall back silently
    /// (c) return a real monospace face when given a legit family.
    ///
    /// (b) is load-bearing: a font family the user picked in Settings
    /// may not be installed on a different machine / after a macOS
    /// reinstall. Silent fallback to SF Mono keeps the Settings value
    /// portable instead of leaving tiles in a half-rendered state.
    func testFontFamilyLookupFallsBackToMonospace() {
        let empty = FontMetrics.font(named: "", size: 13, scale: 2)
        XCTAssertTrue(
            CTFontGetSymbolicTraits(empty.font).contains(.monoSpaceTrait),
            "empty font name must fall back to a monospace font"
        )

        let bogus = FontMetrics.font(named: "No-Such-Font-XYZ", size: 13, scale: 2)
        XCTAssertTrue(
            CTFontGetSymbolicTraits(bogus.font).contains(.monoSpaceTrait),
            "unknown family name must fall back to a monospace font"
        )

        // Menlo ships with every macOS install since 10.6 — safe to
        // hard-code as the positive-path probe.
        let menlo = FontMetrics.font(named: "Menlo", size: 13, scale: 2)
        XCTAssertTrue(
            CTFontGetSymbolicTraits(menlo.font).contains(.monoSpaceTrait),
            "Menlo must resolve as monospace"
        )
        let familyName = CTFontCopyFamilyName(menlo.font) as String
        XCTAssertEqual(familyName, "Menlo", "Menlo family should round-trip")
    }

    /// The settings picker builds its list from `monospaceFamilyNames()`.
    /// It must return at least a couple of families, include Menlo
    /// (macOS stock), and be sorted (users expect alphabetical order).
    func testMonospaceFamilyNamesIncludesStockFonts() {
        let families = FontMetrics.monospaceFamilyNames()
        XCTAssertFalse(families.isEmpty, "expected at least one monospace family")
        XCTAssertTrue(
            families.contains("Menlo"),
            "expected Menlo in monospace family list (got: \(families.prefix(10)))"
        )
        XCTAssertEqual(families, families.sorted(), "family list must be sorted")
    }

    // MARK: Scroll clamp

    /// Scrolling into history must never exceed the available scrollback
    /// rows. Before this clamp, a long trackpad flick would drift past the
    /// top, showing blank rows + silently banking inertia that ate the
    /// first scroll-back-down event.
    func testScrollOffsetClampsAtAvailableScrollback() {
        // Scroll 50 lines up when only 20 rows are buffered.
        let result = TerminalMTKView.clampedScrollOffset(
            current: 0, lines: 50, available: 20
        )
        XCTAssertEqual(result, 20, "offset must cap at available history")
    }

    /// Scrolling back toward live must bottom out at 0 — negative offsets
    /// would crash `scrollbackSnapshot(offset:rows:)` in Rust.
    func testScrollOffsetClampsAtZeroOnScrollDown() {
        let result = TerminalMTKView.clampedScrollOffset(
            current: 3, lines: -100, available: 10
        )
        XCTAssertEqual(result, 0)
    }

    /// Within the valid range, the clamp is a pure add — no drift, no
    /// off-by-one on the common "wheel 1 line at a time" path.
    func testScrollOffsetPassesThroughWithinBounds() {
        XCTAssertEqual(
            TerminalMTKView.clampedScrollOffset(current: 5, lines: 3, available: 100),
            8
        )
        XCTAssertEqual(
            TerminalMTKView.clampedScrollOffset(current: 5, lines: -2, available: 100),
            3
        )
    }

    /// Zero scrollback (fresh session, nothing evicted yet) must clamp to
    /// 0 regardless of scroll direction — we've seen wheel events fire
    /// before the grid has output anything.
    func testScrollOffsetClampsAtZeroWhenNoHistory() {
        XCTAssertEqual(
            TerminalMTKView.clampedScrollOffset(current: 0, lines: 10, available: 0),
            0
        )
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

    // MARK: - DrawGuardTracker (pure, no Metal needed)

    /// Fresh tracker starts with every counter at zero and no recovery
    /// flag armed. Establishes the baseline that recordSuccess() relies
    /// on (calling it repeatedly must stay quiescent).
    func testDrawGuardTrackerStartsQuiescent() {
        var tracker = DrawGuardTracker()
        XCTAssertEqual(tracker.totalNilDrawable, 0)
        XCTAssertEqual(tracker.totalNilRPD, 0)
        XCTAssertEqual(tracker.totalNilCommandBuffer, 0)
        XCTAssertEqual(tracker.consecutiveNilDrawable, 0)
        XCTAssertFalse(tracker.needsDrawableRecovery)
        XCTAssertFalse(tracker.consumeRecoveryFlag())
        tracker.recordSuccess()
        XCTAssertEqual(tracker.consecutiveNilDrawable, 0)
    }

    /// First three nil-drawable events must log (diagnosis budget),
    /// the fourth must NOT log (quiet period), and the 30th consecutive
    /// must log the one-time "stuck" signal regardless of budget.
    func testDrawGuardTrackerLogBudgetAndStuckSignal() {
        var tracker = DrawGuardTracker()
        // First three: should log, none are the stuck signal.
        for i in 1...3 {
            let action = tracker.recordNilDrawable()
            XCTAssertTrue(action.shouldLog, "event \(i) should log within budget")
            XCTAssertFalse(action.isStuckSignal, "event \(i) is not the stuck signal")
        }
        // Fourth through 29th: budget exhausted, none should log.
        for i in 4..<DrawGuardTracker.stuckSignalThreshold {
            let action = tracker.recordNilDrawable()
            XCTAssertFalse(action.shouldLog, "event \(i) is over budget and not stuck yet")
            XCTAssertFalse(action.isStuckSignal)
        }
        // 30th consecutive: the stuck signal fires.
        let stuck = tracker.recordNilDrawable()
        XCTAssertTrue(stuck.shouldLog, "stuck signal must log even past budget")
        XCTAssertTrue(stuck.isStuckSignal)
        XCTAssertEqual(tracker.consecutiveNilDrawable, DrawGuardTracker.stuckSignalThreshold)
    }

    /// Every nil-drawable arms the recovery flag for the next draw tick.
    /// `consumeRecoveryFlag` returns it and clears it so the view's
    /// recovery runs exactly once per failure streak.
    func testDrawGuardTrackerRecoveryFlagHandshake() {
        var tracker = DrawGuardTracker()
        _ = tracker.recordNilDrawable()
        XCTAssertTrue(tracker.needsDrawableRecovery)
        XCTAssertTrue(tracker.consumeRecoveryFlag())
        XCTAssertFalse(tracker.needsDrawableRecovery)
        XCTAssertFalse(tracker.consumeRecoveryFlag(), "second consume is a no-op")

        // Arm again, then a successful draw clears the flag without
        // waiting for consume.
        _ = tracker.recordNilDrawable()
        XCTAssertTrue(tracker.needsDrawableRecovery)
        tracker.recordSuccess()
        XCTAssertFalse(tracker.needsDrawableRecovery)
        XCTAssertEqual(tracker.consecutiveNilDrawable, 0)
    }

    /// RPD and command-buffer failures track independently — they don't
    /// share a counter or a budget with the drawable failures. Ensures a
    /// wedged drawable pool doesn't quietly mask later RPD failures.
    func testDrawGuardTrackerIndependentCountersPerFailureKind() {
        var tracker = DrawGuardTracker()
        _ = tracker.recordNilDrawable()
        _ = tracker.recordNilDrawable()
        XCTAssertEqual(tracker.totalNilDrawable, 2)
        XCTAssertEqual(tracker.totalNilRPD, 0)
        XCTAssertEqual(tracker.totalNilCommandBuffer, 0)

        // RPD budget is independent: its own first three should log.
        for i in 1...DrawGuardTracker.initialLogBudget {
            let action = tracker.recordNilRPD()
            XCTAssertTrue(action.shouldLog, "RPD event \(i) within budget should log")
        }
        XCTAssertFalse(tracker.recordNilRPD().shouldLog, "budget exhausted")
        XCTAssertEqual(tracker.totalNilRPD, DrawGuardTracker.initialLogBudget + 1)

        // Command-buffer counter also independent, still at zero entries.
        for i in 1...DrawGuardTracker.initialLogBudget {
            XCTAssertTrue(tracker.recordNilCommandBuffer().shouldLog,
                          "CB event \(i) within budget should log")
        }
        XCTAssertFalse(tracker.recordNilCommandBuffer().shouldLog)
        XCTAssertEqual(tracker.totalNilCommandBuffer, DrawGuardTracker.initialLogBudget + 1)
    }

    /// A success in the middle of a nil-drawable streak resets the
    /// consecutive counter, so the next streak must start over before
    /// triggering the stuck signal. This is the "tile recovered on its
    /// own" case — no stale stuck log.
    func testDrawGuardTrackerSuccessResetsConsecutiveStreak() {
        var tracker = DrawGuardTracker()
        for _ in 0..<10 {
            _ = tracker.recordNilDrawable()
        }
        XCTAssertEqual(tracker.consecutiveNilDrawable, 10)
        tracker.recordSuccess()
        XCTAssertEqual(tracker.consecutiveNilDrawable, 0)

        // New streak: doesn't trigger stuck signal until threshold count
        // of consecutive nils starts fresh.
        for i in 1..<DrawGuardTracker.stuckSignalThreshold {
            let action = tracker.recordNilDrawable()
            XCTAssertFalse(action.isStuckSignal, "streak event \(i) is pre-threshold")
        }
        let stuck = tracker.recordNilDrawable()
        XCTAssertTrue(stuck.isStuckSignal)
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
