import XCTest
import Metal
@testable import Tado

/// Performance baselines for the Metal renderer. Each test wraps a
/// hot path in an XCTest `.measure {}` block — Xcode / `swift test`
/// runs 10 iterations and reports mean + std.dev. These tests do not
/// assert a threshold; they exist to produce numbers for
/// `bench/BENCH.md` and to surface regressions visibly when someone
/// runs `make bench`.
///
/// Skipped gracefully on headless machines (no Metal device).
final class RendererBenchTests: XCTestCase {

    /// Typical 80×24 terminal worth of text, rendered offscreen.
    func testRenderOffscreen_80x24_dense() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, cols: 80, rows: 24)
        // Dense ASCII grid so every cell carries a real glyph.
        let snap = TadoCore.Snapshot.synthetic(cols: 80, rows: 24) { col, row in
            let base = UInt32("A".unicodeScalars.first!.value)
            return TadoCore.Cell(
                ch: base + UInt32((row * 80 + col) % 26),
                fg: 0xFFFFFFFF,
                bg: 0x000000FF,
                attrs: 0
            )
        }
        renderer.upload(snapshot: snap)

        let w = Int(renderer.metrics.cellWidth) * 80
        let h = Int(renderer.metrics.cellHeight) * 24

        measure {
            _ = renderer.renderOffscreen(width: w, height: h)
        }
    }

    /// 200×50 grid — past typical terminal size, stresses the glyph
    /// lookup + instance buffer. Useful for catching O(n²) regressions
    /// that don't show at 80×24.
    func testRenderOffscreen_200x50_dense() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, cols: 200, rows: 50)
        let snap = TadoCore.Snapshot.synthetic(cols: 200, rows: 50) { col, row in
            let base = UInt32("a".unicodeScalars.first!.value)
            return TadoCore.Cell(
                ch: base + UInt32((row * 200 + col) % 26),
                fg: 0xE8E8E8FF,
                bg: 0x000000FF,
                attrs: 0
            )
        }
        renderer.upload(snapshot: snap)

        let w = Int(renderer.metrics.cellWidth) * 200
        let h = Int(renderer.metrics.cellHeight) * 50

        measure {
            _ = renderer.renderOffscreen(width: w, height: h)
        }
    }

    /// Worst-case glyph-atlas churn: every frame introduces a new
    /// codepoint the atlas hasn't rasterized yet. Forces the GPU
    /// lookup-buffer rebuild branch in `commit`.
    func testRenderOffscreen_freshGlyphsEveryFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, cols: 40, rows: 10)
        let w = Int(renderer.metrics.cellWidth) * 40
        let h = Int(renderer.metrics.cellHeight) * 10

        // Start at U+2500 (Box Drawing block) — 256 fresh glyphs
        // available without needing font fallback.
        var nextCh: UInt32 = 0x2500
        measure {
            let snap = TadoCore.Snapshot.synthetic(cols: 40, rows: 10) { _, _ in
                let ch = nextCh
                nextCh = nextCh &+ 1
                return TadoCore.Cell(
                    ch: ch, fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0
                )
            }
            renderer.upload(snapshot: snap)
            _ = renderer.renderOffscreen(width: w, height: h)
        }
    }
}
