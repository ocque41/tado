import Foundation
import Metal

/// Process-wide cache of compiled `MTLLibrary` + `MTLRenderPipelineState`
/// for the terminal renderer.
///
/// **Why this exists.** `MetalTerminalRenderer.init` used to do three
/// things synchronously on @MainActor every time a `TerminalMTKView`
/// was created (i.e. every tile mount AND every off-screen
/// virtualization re-mount):
///
/// 1. `String(contentsOf: Shaders.metal)` — synchronous file read.
/// 2. `device.makeLibrary(source:)` — runtime Metal shader compile,
///    100 ms–2 s on cold launch.
/// 3. `device.makeRenderPipelineState(descriptor:)` — synchronous
///    pipeline state creation; another 50–500 ms cold.
///
/// On a freshly-launched Tado, the first tile spawn (canvas todo,
/// architect, panel-driven Eternal — doesn't matter how it kicked
/// off) hit all three on the UI thread back-to-back, blocking the
/// runloop for a full second or more. The placeholder
/// `tado-core spawn pending…` would render once and then freeze
/// because @MainActor was busy compiling shaders. THIS is the
/// "freeze on first terminal" the user reported across four prior
/// smooth-software passes.
///
/// **The fix.** Compile once per `MTLDevice` and reuse. Pre-warm at
/// app launch on a detached `.utility` task so even the first tile
/// init finds the library + pipeline already cached. Subsequent
/// tile inits (and re-mounts) hit a pure dictionary lookup.
///
/// **Threading.** The cache is internally `NSLock`-guarded so it can
/// be primed off-main and read on @MainActor. Methods are
/// `nonisolated` for the same reason. `MTLDevice`,
/// `MTLLibrary`, and `MTLRenderPipelineState` are all documented as
/// thread-safe by Apple — sharing them across actors is fine.
final class MetalPipelineCache: @unchecked Sendable {
    static let shared = MetalPipelineCache()

    private let lock = NSLock()
    private var libraryByDevice: [ObjectIdentifier: MTLLibrary] = [:]
    private var pipelineByKey: [PipelineKey: MTLRenderPipelineState] = [:]

    private struct PipelineKey: Hashable {
        let deviceID: ObjectIdentifier
        let pixelFormat: UInt
        let vertexName: String
        let fragmentName: String
    }

    private init() {}

    /// Get (or compile + cache) the terminal shader library for one
    /// device. Throws on file-read or shader-compile failure — same
    /// failure modes the old inline path had, just funnelled through
    /// here so the renderer doesn't pay the cost twice.
    func library(for device: MTLDevice) throws -> MTLLibrary {
        let key = ObjectIdentifier(device)
        lock.lock()
        if let cached = libraryByDevice[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Compile outside the lock — `makeLibrary` is the slow step.
        // Two threads racing to compile the same library is harmless
        // (the second one's compile gets thrown away on insert).
        let library: MTLLibrary
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            library = try device.makeLibrary(source: source, options: nil)
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else {
            throw RendererError.libraryCreationFailed
        }

        lock.lock()
        // First writer wins. If another thread already inserted, hand
        // back theirs — `MTLLibrary` is reference-counted, the loser
        // is just dropped.
        if let existing = libraryByDevice[key] {
            lock.unlock()
            return existing
        }
        libraryByDevice[key] = library
        lock.unlock()
        return library
    }

    /// Get (or build + cache) a render pipeline state for the given
    /// device + pixel format + shader entry points. Same lock
    /// discipline as `library(for:)`.
    func pipeline(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        vertexName: String,
        fragmentName: String
    ) throws -> MTLRenderPipelineState {
        let key = PipelineKey(
            deviceID: ObjectIdentifier(device),
            pixelFormat: UInt(pixelFormat.rawValue),
            vertexName: vertexName,
            fragmentName: fragmentName
        )
        lock.lock()
        if let cached = pipelineByKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library = try library(for: device)
        guard let vertexFn = library.makeFunction(name: vertexName),
              let fragFn = library.makeFunction(name: fragmentName) else {
            throw RendererError.pipelineCreationFailed
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        let state = try device.makeRenderPipelineState(descriptor: desc)

        lock.lock()
        if let existing = pipelineByKey[key] {
            lock.unlock()
            return existing
        }
        pipelineByKey[key] = state
        lock.unlock()
        return state
    }

    /// Pre-warm the cache for the system default device so the first
    /// tile spawn doesn't pay the compile on @MainActor. Called from
    /// `TadoApp` boot at `.utility` priority. Idempotent — safe to
    /// call from any thread, multiple times.
    ///
    /// `pixelFormat` matches what `TerminalMTKView` configures
    /// (`.bgra8Unorm`). If that ever changes the pre-warm becomes a
    /// no-op (cold compile still happens on first tile) — not a
    /// correctness bug, just lost preheat.
    static func prewarm() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        do {
            _ = try MetalPipelineCache.shared.pipeline(
                device: device,
                pixelFormat: .bgra8Unorm,
                vertexName: "terminal_vertex",
                fragmentName: "terminal_fragment"
            )
        } catch {
            // Best-effort pre-warm. If compile fails here, the first
            // tile init will fail too with the same error and surface
            // it in the placeholder branch — consistent with the
            // pre-cache behavior.
            NSLog("tado: MetalPipelineCache pre-warm failed: \(error)")
        }
    }
}
