import Foundation
import Metal
import MetalKit
import simd

/// Renders one terminal grid to an `MTKView`-compatible target.
///
/// Designed for per-tile ownership in Phase 2. A future refactor can share
/// the pipeline + atlas across many tiles (one-draw-call-per-tile in a
/// single encoder) — the current split keeps the first-green path simple.
///
/// Usage:
/// ```swift
/// let renderer = try MetalTerminalRenderer(device: device, cols: 80, rows: 24)
/// renderer.upload(snapshot: session.snapshotFull()!)   // or snapshotDirty
/// renderer.render(into: view)
/// ```
final class MetalTerminalRenderer {
    // MARK: - Uniform / instance layouts (MUST match Shaders.metal exactly)

    struct Uniforms {
        var viewport: SIMD2<Float> = .zero
        var cellSize: SIMD2<Float> = .zero
        var atlasSize: SIMD2<Float> = .zero
        var cols: UInt32 = 0
        var rows: UInt32 = 0
        var cursorX: UInt32 = 0
        var cursorY: UInt32 = 0
        var cursorVisible: UInt32 = 1
        var _pad0: UInt32 = 0
        var _pad1: UInt32 = 0
        var _pad2: UInt32 = 0
    }

    /// Matches `TadoCore.Cell` and `grid::Cell` exactly.
    struct CellInstance: Equatable {
        var ch: UInt32
        var fg: UInt32
        var bg: UInt32
        var attrs: UInt32
    }

    // MARK: - State

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let atlas: GlyphAtlas
    let metrics: FontMetrics

    private(set) var cols: UInt32
    private(set) var rows: UInt32

    private var cellBuffer: MTLBuffer
    private var uniforms = Uniforms()
    private var glyphLookup: MTLBuffer
    /// Largest codepoint the current `glyphLookup` buffer covers (exclusive).
    /// Starts at ASCII + Latin-1; grows to BMP when any char ≥ lookupMax is
    /// rasterized. Extending past BMP (emoji etc.) needs a sparse lookup
    /// — Phase 3 territory, currently handled by falling back to `hasGlyph=0`.
    private var lookupMax: UInt32 = 0x100
    /// Atlas modCount snapshot at the time `glyphLookup` was last built.
    /// A mismatch means fresh glyphs were rasterized and the GPU table
    /// is stale — see `commit` for the rebuild decision.
    private var lastLookupModCount: Int = -1

    /// Cached local grid so `snapshotDirty` can patch into a persistent array
    /// without the renderer seeing stale cells between frames.
    private var localCells: [CellInstance]

    // MARK: - Init

    init(
        device: MTLDevice,
        metrics: FontMetrics = FontMetrics.defaultMono(),
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        atlasSize: Int = 2048
    ) throws {
        self.device = device
        self.metrics = metrics
        self.cols = cols
        self.rows = rows

        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueCreationFailed
        }
        self.commandQueue = queue

        self.atlas = try GlyphAtlas(device: device, metrics: metrics, atlasSize: atlasSize)

        // Load shader library. SwiftPM's `.process()` rule only COPIES the
        // .metal source into Bundle.module — it doesn't precompile it (no
        // Xcode metal compiler is invoked by `swift build`). So we compile
        // from source at runtime, which takes ~100ms on first launch and
        // is cached by Metal afterwards.
        let library: MTLLibrary
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            library = try device.makeLibrary(source: source, options: nil)
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else {
            throw RendererError.libraryCreationFailed
        }

        guard let vertexFn = library.makeFunction(name: "terminal_vertex"),
              let fragFn = library.makeFunction(name: "terminal_fragment") else {
            throw RendererError.pipelineCreationFailed
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.sAddressMode = .clampToEdge
        sDesc.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: sDesc) else {
            throw RendererError.pipelineCreationFailed
        }
        self.sampler = samp

        // Instance buffer sized for the full grid.
        let cellCount = Int(cols) * Int(rows)
        self.localCells = Array(
            repeating: CellInstance(ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0),
            count: cellCount
        )
        let stride = MemoryLayout<CellInstance>.stride
        guard let buf = device.makeBuffer(length: stride * cellCount, options: .storageModeShared),
              let lookup = atlas.buildLookupBuffer(device: device, maxCodepoint: lookupMax) else {
            throw RendererError.pipelineCreationFailed
        }
        self.cellBuffer = buf
        self.glyphLookup = lookup
    }

    // MARK: - Upload

    func resize(cols: UInt32, rows: UInt32) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        let cellCount = Int(cols) * Int(rows)
        self.localCells = Array(
            repeating: CellInstance(ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0),
            count: cellCount
        )
        let stride = MemoryLayout<CellInstance>.stride
        if let buf = device.makeBuffer(length: stride * cellCount, options: .storageModeShared) {
            self.cellBuffer = buf
        }
    }

    /// Apply a snapshot. Uses `dirtyRows` to patch only the rows that changed.
    /// Caller supplies the raw cells flattened in row-major order, with one
    /// row per entry in `dirtyRows`.
    func upload(snapshot: TadoCore.Snapshot) {
        if UInt32(snapshot.cols) != cols || UInt32(snapshot.rows) != rows {
            resize(cols: UInt32(snapshot.cols), rows: UInt32(snapshot.rows))
        }

        // Patch dirty rows into local mirror.
        let colsInt = Int(cols)
        for (i, rowIdx) in snapshot.dirtyRows.enumerated() {
            let dstStart = Int(rowIdx) * colsInt
            let srcStart = i * colsInt
            guard srcStart + colsInt <= snapshot.cells.count,
                  dstStart + colsInt <= localCells.count else { continue }
            for c in 0..<colsInt {
                let src = snapshot.cells[srcStart + c]
                rasterizeIfNew(src.ch)
                localCells[dstStart + c] = CellInstance(
                    ch: src.ch,
                    fg: src.fg,
                    bg: src.bg,
                    attrs: src.attrs
                )
            }
        }

        commit(uniformsCursorX: UInt32(snapshot.cursorX),
               uniformsCursorY: UInt32(snapshot.cursorY),
               cursorVisible: snapshot.cursorVisible ? 1 : 0)
    }

    /// Compose a view of the grid with `scrollOffset` lines of history
    /// showing at the top. `scrollOffset = 0` behaves exactly like
    /// `upload(snapshot:)` (all live). `scrollOffset == rows` shows pure
    /// scrollback. Intermediate values show `scrollOffset` history rows on
    /// top and `(rows - scrollOffset)` live rows below. Cursor is hidden
    /// when scrolled back so users don't chase a phantom caret.
    func uploadScrolled(
        live: TadoCore.Snapshot,
        scrollback: TadoCore.Scrollback?,
        scrollOffset: Int
    ) {
        if UInt32(live.cols) != cols || UInt32(live.rows) != rows {
            resize(cols: UInt32(live.cols), rows: UInt32(live.rows))
        }
        let colsInt = Int(cols)
        let rowsInt = Int(rows)
        let clampedOffset = max(0, min(rowsInt, scrollOffset))

        // 1) Top `clampedOffset` rows: scrollback (oldest at top-most).
        if clampedOffset > 0, let sb = scrollback {
            let sbCols = Int(sb.cols)
            // Scrollback snapshot is oldest→newest. We want to place
            // `clampedOffset` rows starting from history_start so that the
            // NEWEST scrollback row lands at display row `clampedOffset-1`.
            let available = Int(sb.rows)
            let take = min(clampedOffset, available)
            let srcRowStart = max(0, available - take)
            for i in 0..<take {
                let dstRow = clampedOffset - take + i
                for c in 0..<colsInt {
                    let sbIdx = (srcRowStart + i) * sbCols + c
                    let cell: CellInstance
                    if sbIdx < sb.cells.count, c < sbCols {
                        let src = sb.cells[sbIdx]
                        rasterizeIfNew(src.ch)
                        cell = CellInstance(ch: src.ch, fg: src.fg, bg: src.bg, attrs: src.attrs)
                    } else {
                        cell = CellInstance(ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0)
                    }
                    localCells[dstRow * colsInt + c] = cell
                }
            }
            // Blank any top rows we couldn't fill (more offset than history).
            for dstRow in 0..<(clampedOffset - take) {
                for c in 0..<colsInt {
                    localCells[dstRow * colsInt + c] = CellInstance(
                        ch: 0, fg: 0xE8E8E8FF, bg: 0x000000FF, attrs: 0
                    )
                }
            }
        }

        // 2) Bottom `(rows - clampedOffset)` rows: top of live grid.
        let liveRows = rowsInt - clampedOffset
        if liveRows > 0 {
            // live snapshot `cells` is row-major `cols * rows`.
            for r in 0..<liveRows {
                for c in 0..<colsInt {
                    let src = live.cells[r * colsInt + c]
                    rasterizeIfNew(src.ch)
                    let dstRow = clampedOffset + r
                    localCells[dstRow * colsInt + c] = CellInstance(
                        ch: src.ch, fg: src.fg, bg: src.bg, attrs: src.attrs
                    )
                }
            }
        }

        // Hide cursor when scrolled back OR when DECTCEM has hidden it.
        let cursorVisible: UInt32 =
            (clampedOffset == 0 && live.cursorVisible) ? 1 : 0
        commit(uniformsCursorX: UInt32(live.cursorX),
               uniformsCursorY: UInt32(live.cursorY) + UInt32(clampedOffset),
               cursorVisible: cursorVisible)
    }

    /// Eagerly make sure `ch` has a slot in the atlas (rasterizing if first
    /// time seen) and that `lookupMax` covers it. The renderer decides
    /// whether to rebuild the GPU lookup buffer by comparing the atlas's
    /// modCount against the last built one — that signal is accurate even
    /// when this method doesn't do anything observable (no in/out bool
    /// needed).
    private func rasterizeIfNew(_ ch: UInt32) {
        // Zero means "blank cell" (handled by shader short-circuit) — never
        // rasterize. Also cap at BMP: beyond that we'd need sparse lookup,
        // so fall back to a visible placeholder row instead of blowing
        // memory on a 4 MB lookup buffer for one emoji.
        guard ch != 0, ch < 0x10000 else { return }
        _ = atlas.uvRect(for: ch)
        if ch >= lookupMax {
            // Grow lookup bound to cover this codepoint. Round up to the
            // next 256-codepoint boundary so we don't thrash the GPU
            // buffer rebuild for codepoints arriving in sequence.
            let rounded = (ch | 0xFF) + 1
            lookupMax = min(rounded, 0x10000)
        }
    }

    private func commit(
        uniformsCursorX: UInt32,
        uniformsCursorY: UInt32,
        cursorVisible: UInt32
    ) {
        let ptr = cellBuffer.contents().bindMemory(to: CellInstance.self, capacity: localCells.count)
        for i in 0..<localCells.count {
            ptr[i] = localCells[i]
        }

        // Rebuild the GPU lookup when either:
        //   (a) the atlas rasterized new glyphs this pass (modCount bumped), or
        //   (b) lookupMax grew past the last buffer's coverage.
        // The `>` on modCount is a weak signal because the initial build
        // happens at modCount=2 (blank + space); use `!=` so the first real
        // upload (modCount becomes 3+) triggers a rebuild.
        let neededCodepoint = lookupMax
        let builtCodepoint = UInt32(glyphLookup.length / MemoryLayout<SIMD4<Float>>.stride)
        if atlas.modCount != lastLookupModCount || neededCodepoint > builtCodepoint {
            if let lookup = atlas.buildLookupBuffer(device: device, maxCodepoint: lookupMax) {
                self.glyphLookup = lookup
                self.lastLookupModCount = atlas.modCount
            }
        }

        uniforms.cursorX = uniformsCursorX
        uniforms.cursorY = uniformsCursorY
        uniforms.cursorVisible = cursorVisible
    }

    // MARK: - Draw

    /// Encode a draw into the given command buffer and render pass. Caller
    /// owns the drawable presentation — in Phase 2.2 this is invoked from
    /// `MTKView.draw(in:)`.
    func encode(
        into commandBuffer: MTLCommandBuffer,
        passDescriptor: MTLRenderPassDescriptor,
        viewportPixels: CGSize
    ) {
        uniforms.viewport = SIMD2<Float>(Float(viewportPixels.width), Float(viewportPixels.height))
        uniforms.cellSize = SIMD2<Float>(Float(metrics.cellWidth), Float(metrics.cellHeight))
        uniforms.atlasSize = SIMD2<Float>(Float(atlas.atlasSize), Float(atlas.atlasSize))
        uniforms.cols = cols
        uniforms.rows = rows

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(cellBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(glyphLookup, offset: 0, index: 2)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let instanceCount = Int(cols) * Int(rows)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
        encoder.endEncoding()
    }

    /// Convenience for offscreen tests — renders into a fresh `MTLTexture`
    /// and returns it. Never call from the hot render path.
    func renderOffscreen(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cb = commandQueue.makeCommandBuffer() else { return nil }
        encode(into: cb, passDescriptor: pass, viewportPixels: CGSize(width: width, height: height))
        cb.commit()
        cb.waitUntilCompleted()
        return target
    }
}
