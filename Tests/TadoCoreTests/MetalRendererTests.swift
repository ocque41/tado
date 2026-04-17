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
        let renderer = try MetalTerminalRenderer(device: device, cols: 10, rows: 3)
        XCTAssertEqual(renderer.cols, 10)
        XCTAssertEqual(renderer.rows, 3)
    }

    func testRendersGlyphsOffscreen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try MetalTerminalRenderer(device: device, cols: 20, rows: 3)

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
        let renderer = try MetalTerminalRenderer(device: device, cols: 4, rows: 1)
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

        let renderer = try MetalTerminalRenderer(device: device, cols: 10, rows: 2)
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
