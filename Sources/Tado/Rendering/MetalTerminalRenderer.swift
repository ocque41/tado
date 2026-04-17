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
    private var lookupMax: UInt32 = 0x80

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
        var sawNewChar = false
        for (i, rowIdx) in snapshot.dirtyRows.enumerated() {
            let dstStart = Int(rowIdx) * colsInt
            let srcStart = i * colsInt
            guard srcStart + colsInt <= snapshot.cells.count,
                  dstStart + colsInt <= localCells.count else { continue }
            for c in 0..<colsInt {
                let src = snapshot.cells[srcStart + c]
                // Memoize atlas rasterization. Brand-new glyphs trigger a
                // lookup table rebuild at the end of this upload.
                if src.ch < lookupMax, atlas.uvRect(for: src.ch) != nil {
                    // already present or just inserted
                } else if src.ch >= lookupMax, atlas.uvRect(for: src.ch) != nil {
                    // outside our current lookup bound; expand table
                    lookupMax = max(lookupMax, src.ch + 1)
                    sawNewChar = true
                }
                localCells[dstStart + c] = CellInstance(
                    ch: src.ch,
                    fg: src.fg,
                    bg: src.bg,
                    attrs: src.attrs
                )
            }
        }

        // Copy cell mirror into the GPU buffer.
        let ptr = cellBuffer.contents().bindMemory(to: CellInstance.self, capacity: localCells.count)
        for i in 0..<localCells.count {
            ptr[i] = localCells[i]
        }

        // Rebuild lookup if we rasterized anything new. Cheap for ASCII+Latin.
        if sawNewChar, let lookup = atlas.buildLookupBuffer(device: device, maxCodepoint: lookupMax) {
            self.glyphLookup = lookup
        } else if lookupMax > 0 {
            // Even if no new char, glyph could have been newly rasterized
            // into an existing slot; rebuild once per upload is OK-cheap.
            if let lookup = atlas.buildLookupBuffer(device: device, maxCodepoint: lookupMax) {
                self.glyphLookup = lookup
            }
        }

        uniforms.cursorX = UInt32(snapshot.cursorX)
        uniforms.cursorY = UInt32(snapshot.cursorY)
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
