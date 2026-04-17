import AppKit
import Metal
import MetalKit
import SwiftUI

/// SwiftUI bridge for a Metal-rendered terminal tile backed by a
/// `TadoCore.Session`. This is the Phase 2 replacement for
/// `TerminalNSViewRepresentable` (SwiftTerm + Cocoa). Mount in
/// `TerminalTileView` behind the `useMetalRenderer` feature flag.
///
/// Render loop: the underlying `TerminalMTKView` schedules itself to draw
/// at ~30 fps when output is active; falls idle when nothing changes, so
/// an off-screen or silent tile costs ~0 GPU. The Rust PTY reader keeps
/// running in the background regardless.
struct MetalTerminalView: NSViewRepresentable {
    let session: TadoCore.Session
    let cols: UInt16
    let rows: UInt16

    func makeNSView(context: Context) -> TerminalMTKView {
        let view = TerminalMTKView(session: session, cols: cols, rows: rows)
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.resizeIfNeeded(cols: cols, rows: rows)
    }

    static func dismantleNSView(_ nsView: TerminalMTKView, coordinator: ()) {
        nsView.stop()
    }
}

/// Concrete MTKView subclass that owns the renderer + drive loop + input.
/// Exposed as a class (not wrapped) so callers can adjust frame rate or
/// pause directly.
final class TerminalMTKView: MTKView {
    let session: TadoCore.Session
    private(set) var cols: UInt16
    private(set) var rows: UInt16

    private var renderer: MetalTerminalRenderer?
    /// Set by the render tick when the last snapshot had dirty rows. Used
    /// to drive an adaptive frame rate: active tiles run at 30 fps, idle
    /// tiles drop to 4 fps (poll for new dirty rows).
    private var hadDirtyLastFrame: Bool = false
    /// Key-modifier adjusted ESC sequences — built lazily per keyDown.
    private lazy var keymap = TerminalKeymap()

    init(session: TadoCore.Session, cols: UInt16, rows: UInt16) {
        self.session = session
        self.cols = cols
        self.rows = rows

        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)

        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        self.colorPixelFormat = .bgra8Unorm
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 30
        self.wantsLayer = true

        if let device = device {
            do {
                self.renderer = try MetalTerminalRenderer(
                    device: device,
                    cols: UInt32(cols),
                    rows: UInt32(rows)
                )
            } catch {
                NSLog("tado: MetalTerminalRenderer init failed: \(error)")
            }
        }

        // Render delegate; MTKView calls us every frame.
        self.delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("not supported")
    }

    // MARK: - Lifecycle

    func stop() {
        self.isPaused = true
        session.kill()
    }

    func resizeIfNeeded(cols newCols: UInt16, rows newRows: UInt16) {
        guard newCols != cols || newRows != rows else { return }
        cols = newCols
        rows = newRows
        renderer?.resize(cols: UInt32(newCols), rows: UInt32(newRows))
        session.resize(cols: newCols, rows: newRows)
    }

    // MARK: - Focus / input

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let bytes = keymap.bytes(for: event)
        if !bytes.isEmpty {
            session.write(bytes)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept plain Cmd-less keystrokes; let SwiftUI handle Cmd+X etc.
        guard !event.modifierFlags.contains(.command) else { return false }
        keyDown(with: event)
        return true
    }
}

extension TerminalMTKView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // nothing — renderer resizes via resizeIfNeeded.
    }

    func draw(in view: MTKView) {
        guard let renderer = renderer,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = renderer.commandQueue.makeCommandBuffer()
        else { return }

        // Pull incremental updates from Rust. Empty dirtyRows = idle tile.
        let snapshot: TadoCore.Snapshot?
        if hadDirtyLastFrame == false && Int.random(in: 0..<8) != 0 {
            // Adaptive throttle: when we've been idle, only poll ~1/8 frames.
            // Keeps GPU quiet for silent tiles without a real CVDisplayLink.
            snapshot = nil
        } else {
            snapshot = session.snapshotDirty()
        }

        if let snap = snapshot {
            if !snap.dirtyRows.isEmpty {
                renderer.upload(snapshot: snap)
                hadDirtyLastFrame = true
            } else {
                hadDirtyLastFrame = false
            }
        }

        let viewportPx = CGSize(
            width: CGFloat(drawable.texture.width),
            height: CGFloat(drawable.texture.height)
        )
        renderer.encode(into: cb, passDescriptor: rpd, viewportPixels: viewportPx)
        cb.present(drawable)
        cb.commit()
    }
}

/// Tiny keymap that translates `NSEvent` keystrokes into the UTF-8 / ESC
/// sequences a PTY expects. Not comprehensive — Phase 2 covers the common
/// cases; xterm mouse reporting and full function-key table land in Phase 3.
struct TerminalKeymap {
    func bytes(for event: NSEvent) -> [UInt8] {
        // Special keys first.
        let keyCode = event.keyCode
        switch keyCode {
        case 36, 76: return [0x0D]                    // Return
        case 51:     return [0x7F]                    // Delete (Backspace)
        case 53:     return [0x1B]                    // Escape
        case 48:     return [0x09]                    // Tab
        case 123:    return [0x1B, 0x5B, 0x44]        // Left
        case 124:    return [0x1B, 0x5B, 0x43]        // Right
        case 125:    return [0x1B, 0x5B, 0x42]        // Down
        case 126:    return [0x1B, 0x5B, 0x41]        // Up
        default: break
        }

        // Character input. `charactersIgnoringModifiers` plus explicit
        // control handling covers Ctrl-<letter>, which otherwise becomes
        // a raw codepoint NSEvent can't represent by itself.
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           let first = chars.first,
           let ascii = first.asciiValue {
            // Map Ctrl+A..Z to 1..26, Ctrl+@ to 0, etc.
            let lower = ascii >= 0x60 ? ascii - 0x60 : (ascii >= 0x40 ? ascii - 0x40 : ascii)
            return [lower & 0x1F]
        }

        if let text = event.characters {
            return Array(text.utf8)
        }
        return []
    }
}
