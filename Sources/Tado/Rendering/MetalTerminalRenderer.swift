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
        // Normalized selection rect, inclusive on both ends. `selActive=0`
        // disables the highlight; the sel* fields are ignored in that case.
        // Matches `struct Uniforms` in Shaders.metal exactly.
        var selStartCol: UInt32 = 0
        var selStartRow: UInt32 = 0
        var selEndCol: UInt32 = 0
        var selEndRow: UInt32 = 0
        var selActive: UInt32 = 0
    }

    /// Matches `TadoCore.Cell` and `grid::Cell` exactly.
    struct CellInstance: Equatable {
        var ch: UInt32
        var fg: UInt32
        var bg: UInt32
        var attrs: UInt32
    }

    /// Cell attribute bit constants — must stay in sync with `grid.rs`
    /// (`ATTR_*`) and `Shaders.metal`. Kept as a Swift namespace so
    /// callsite reads like `attrs & Attr.wide` instead of magic bits.
    ///
    /// Bits 0..7 mirror `grid.rs` ATTR_* constants (Rust owns them).
    /// Bit 8 (`colorGlyph`) is renderer-local: the Rust core does not
    /// know about fonts, so the Swift renderer ORs this bit in after
    /// the glyph atlas tells us the resolved font is color (Apple Color
    /// Emoji). The shader samples the color atlas instead of the mono
    /// atlas when the bit is set.
    enum Attr {
        static let bold: UInt32          = 1 << 0
        static let italic: UInt32        = 1 << 1
        static let underline: UInt32     = 1 << 2
        static let reverse: UInt32       = 1 << 3
        static let strikethrough: UInt32 = 1 << 4
        static let dim: UInt32           = 1 << 5
        static let wide: UInt32          = 1 << 6
        static let wideFiller: UInt32    = 1 << 7
        static let colorGlyph: UInt32    = 1 << 8
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
    /// BMP slots (< 0x10000) are keyed by their Unicode scalar. Astral
    /// slots (>= 0x10000, up to `astralSlotEnd`) are keyed by a dense
    /// round-robin-allocated slot; the renderer remaps real astral
    /// codepoints into those slots on upload so any single cell's
    /// ch always fits in the lookup buffer.
    private var lookupMax: UInt32 = 0x100
    /// Atlas modCount snapshot at the time `glyphLookup` was last built.
    /// A mismatch means fresh glyphs were rasterized and the GPU table
    /// is stale — see `commit` for the rebuild decision.
    private var lastLookupModCount: Int = -1

    // MARK: - Astral slot remapping (Phase 2.19)

    /// Astral slots live at 0x10000..astralSlotEnd. 0x10000 chosen so we
    /// never collide with BMP codepoints the atlas might rasterize.
    private static let astralSlotStart: UInt32 = 0x10000
    /// 4096 slots (0x10000..0x11000). Enough for typical emoji-heavy
    /// sessions; wraps round-robin when exhausted. Kept small so the
    /// lookup buffer stays compact (0x11000 * 16 B ≈ 1 MB).
    private static let astralSlotEnd: UInt32 = 0x11000
    private var astralToSlot: [UInt32: UInt32] = [:]
    private var astralSlotToCodepoint: [UInt32: UInt32] = [:]
    private var nextAstralSlot: UInt32 = astralSlotStart

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

    /// Override the cursor visibility for the next frame. Used by
    /// `TerminalMTKView` to implement the ~530ms blink: during the off
    /// phase the view calls `setCursorBlinkOff(true)` and the shader
    /// hides the cursor regardless of the snapshot's DECTCEM state.
    /// Off-phase never wins over an already-hidden DECTCEM cursor.
    func setCursorBlinkOff(_ off: Bool) {
        if off {
            uniforms.cursorVisible = 0
        }
        // When off==false we leave cursorVisible at whatever the last
        // upload set it to (snapshot's DECTCEM), so a blink-on phase
        // doesn't force a hidden cursor back on.
    }

    /// Set the selection overlay. Coords are cell-space, inclusive on
    /// both ends. The caller passes normalized coords (reading order);
    /// the shader trusts the rectangle semantics as-is. Nil clears.
    func setSelection(start: (col: Int, row: Int)?, end: (col: Int, row: Int)?) {
        guard let start, let end else {
            uniforms.selActive = 0
            return
        }
        uniforms.selStartCol = UInt32(start.col)
        uniforms.selStartRow = UInt32(start.row)
        uniforms.selEndCol = UInt32(end.col)
        uniforms.selEndRow = UInt32(end.row)
        uniforms.selActive = 1
    }

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
                let effectiveCh = rasterizeIfNew(src.ch, isWide: (src.attrs & Attr.wide) != 0)
                let attrs = colorTaggedAttrs(src.attrs, realCh: src.ch)
                localCells[dstStart + c] = CellInstance(
                    ch: effectiveCh,
                    fg: src.fg,
                    bg: src.bg,
                    attrs: attrs
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
                        let effectiveCh = rasterizeIfNew(src.ch, isWide: (src.attrs & Attr.wide) != 0)
                        let attrs = colorTaggedAttrs(src.attrs, realCh: src.ch)
                        cell = CellInstance(ch: effectiveCh, fg: src.fg, bg: src.bg, attrs: attrs)
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
                    let effectiveCh = rasterizeIfNew(src.ch, isWide: (src.attrs & Attr.wide) != 0)
                    let attrs = colorTaggedAttrs(src.attrs, realCh: src.ch)
                    let dstRow = clampedOffset + r
                    localCells[dstRow * colsInt + c] = CellInstance(
                        ch: effectiveCh, fg: src.fg, bg: src.bg, attrs: attrs
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

    /// Ensure `ch` has a slot in the atlas (rasterizing if first time
    /// seen) and a valid GPU lookup entry. Returns the "effective" ch
    /// to write into the cell buffer — same as `ch` for BMP scalars,
    /// a remapped dense slot (in 0x10000..astralSlotEnd) for astral
    /// codepoints. `isWide` controls atlas bitmap width (2× cell width
    /// for CJK). Also grows `lookupMax` in 256-codepoint steps so
    /// sequential writes don't thrash the GPU buffer rebuild.
    private func rasterizeIfNew(_ ch: UInt32, isWide: Bool = false) -> UInt32 {
        // Blank cells short-circuit (shader renders bg only).
        guard ch != 0 else { return 0 }

        if ch < 0x10000 {
            _ = atlas.uvRect(for: ch, cellSpan: isWide ? 2 : 1)
            if ch >= lookupMax {
                let rounded = (ch | 0xFF) + 1
                lookupMax = min(rounded, Self.astralSlotEnd)
            }
            return ch
        }

        // Astral: allocate or reuse a slot in 0x10000..astralSlotEnd.
        let slot: UInt32
        if let existing = astralToSlot[ch] {
            slot = existing
        } else {
            slot = nextAstralSlot
            // Evict previous tenant if we wrap.
            if let old = astralSlotToCodepoint[slot] {
                astralToSlot.removeValue(forKey: old)
            }
            astralToSlot[ch] = slot
            astralSlotToCodepoint[slot] = ch
            nextAstralSlot += 1
            if nextAstralSlot >= Self.astralSlotEnd {
                nextAstralSlot = Self.astralSlotStart
            }
        }
        // Atlas is keyed by the real astral codepoint; the lookup buffer
        // builds from (slot → ch → rect) via slotMap.
        _ = atlas.uvRect(for: ch, cellSpan: isWide ? 2 : 1)
        // Grow lookup to cover this slot.
        if slot >= lookupMax {
            let rounded = (slot | 0xFF) + 1
            lookupMax = min(rounded, Self.astralSlotEnd)
        }
        return slot
    }

    /// OR `Attr.colorGlyph` into `baseAttrs` if the atlas has rasterized
    /// `realCh` into the color atlas. The shader uses this bit to decide
    /// which atlas to sample. `realCh` is the original Unicode scalar —
    /// NOT the astral slot — because the atlas keys by true codepoint.
    private func colorTaggedAttrs(_ baseAttrs: UInt32, realCh: UInt32) -> UInt32 {
        if atlas.isColorGlyph(realCh) {
            return baseAttrs | Attr.colorGlyph
        }
        return baseAttrs
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
        // Astral slots are resolved via the renderer's astralSlotToCodepoint
        // map, passed through to atlas so the lookup buffer points at the
        // right UV for each PUA-above-BMP slot.
        let neededCodepoint = lookupMax
        let builtCodepoint = UInt32(glyphLookup.length / MemoryLayout<SIMD4<Float>>.stride)
        if atlas.modCount != lastLookupModCount || neededCodepoint > builtCodepoint {
            if let lookup = atlas.buildLookupBuffer(
                device: device,
                maxCodepoint: lookupMax,
                slotMap: astralSlotToCodepoint.isEmpty ? nil : astralSlotToCodepoint
            ) {
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
        encoder.setFragmentTexture(atlas.colorTexture, index: 1)
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
