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
    /// Called on the main actor when the PTY produces any output this
    /// frame. Wire to `TerminalSession.markActivity()` so the forward-mode
    /// prompt queue drains identically to the SwiftTerm path.
    var onDirty: (() -> Void)? = nil
    /// Called roughly once per second when no output has arrived.
    /// Wire to `TerminalSession.checkIdle()`.
    var onIdleTick: (() -> Void)? = nil

    func makeNSView(context: Context) -> TerminalMTKView {
        let view = TerminalMTKView(session: session, cols: cols, rows: rows)
        view.onDirty = onDirty
        view.onIdleTick = onIdleTick
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.resizeIfNeeded(cols: cols, rows: rows)
        nsView.onDirty = onDirty
        nsView.onIdleTick = onIdleTick
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

    // MARK: Scrollback state

    /// Lines scrolled back from the live view. 0 = live, positive = history.
    /// Capped by the session's scrollback length each scroll tick.
    private(set) var scrollOffset: Int = 0
    /// Pixel accumulator for trackpad scrolling; one line emitted per
    /// cellHeight of accumulated deltaY. Matches AppKit trackpad cadence.
    private var scrollPixelAccumulator: CGFloat = 0

    // MARK: Cached latest live snapshot

    /// Kept so scroll-back renders can compose against the current live
    /// grid without waiting for a new dirty tick from Rust.
    private var latestLive: TadoCore.Snapshot?

    // MARK: Activity detection hooks (wired by MetalTerminalTileView)

    var onDirty: (() -> Void)?
    var onIdleTick: (() -> Void)?
    private var lastIdleTick: TimeInterval = 0

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

        // Register for file drag-drop. Dropped URLs get written into the
        // PTY as space-joined paths — same UX as SwiftTerm's
        // LoggingTerminalView.
        registerForDraggedTypes([.fileURL])

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
        // Typing always snaps us back to live view — behaves like every
        // other terminal scrollback I've used.
        if scrollOffset != 0 {
            scrollOffset = 0
            scrollPixelAccumulator = 0
        }
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

    // MARK: - Scroll wheel → scrollback offset

    override func scrollWheel(with event: NSEvent) {
        guard let renderer = renderer else { return }
        // Positive deltaY = swipe fingers up on trackpad = scroll content
        // down = show older history. AppKit reports pixels for trackpad
        // (scrollingDeltaY) and lines for mouse (deltaY).
        let pixelDelta: CGFloat
        if event.hasPreciseScrollingDeltas {
            pixelDelta = event.scrollingDeltaY
        } else {
            // Line-based wheels: 3 text lines per wheel notch.
            pixelDelta = event.deltaY * renderer.metrics.cellHeight * 3
        }

        scrollPixelAccumulator += pixelDelta
        let cellH = max(1, renderer.metrics.cellHeight)
        let linesF = scrollPixelAccumulator / cellH
        let lines = Int(linesF.rounded(.towardZero))
        if lines == 0 { return }
        scrollPixelAccumulator -= CGFloat(lines) * cellH

        // AppKit convention: positive deltaY == scroll toward older content.
        // Our offset grows toward history, so add lines directly.
        scrollOffset = max(0, scrollOffset + lines)
    }

    // MARK: - File drag-drop (matches LoggingTerminalView)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        let text = urls.map(\.path).joined(separator: " ")
        session.write(text: text)
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

        // Adaptive poll — keep GPU quiet for silent tiles without a real
        // CVDisplayLink. When scrolled back, always re-poll dirty so the
        // live section (if any) keeps advancing beneath the scrollback.
        let wantsDirty = hadDirtyLastFrame || scrollOffset == 0 || Int.random(in: 0..<4) == 0
        let dirty = wantsDirty ? session.snapshotDirty() : nil
        if let d = dirty, !d.dirtyRows.isEmpty {
            hadDirtyLastFrame = true
            onDirty?()
            if scrollOffset == 0 {
                // Live view path: renderer only needs the dirty rows.
                renderer.upload(snapshot: d)
            }
        } else if dirty?.dirtyRows.isEmpty == true {
            hadDirtyLastFrame = false
        }

        // Rate-limited idle probe — once per second is enough to drive
        // `TerminalSession.checkIdle` transitions without flooding the
        // main actor.
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastIdleTick >= 1.0 {
            lastIdleTick = now
            onIdleTick?()
        }

        // For scrollback we need the FULL live grid (the dirty-row diff
        // doesn't describe unchanged rows). Cache the latest full snapshot
        // and refresh on scroll changes. Cheap: ~80×24×16B = 30 KB memcpy.
        if scrollOffset > 0 {
            if latestLive == nil || dirty?.dirtyRows.isEmpty == false {
                latestLive = session.snapshotFull()
            }
            if let live = latestLive {
                let sb = session.scrollbackSnapshot(
                    offset: 0,
                    rows: scrollOffset
                )
                renderer.uploadScrolled(live: live, scrollback: sb, scrollOffset: scrollOffset)
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

/// Keymap translates `NSEvent` into the UTF-8 / ESC sequences a PTY
/// expects. Mirrors xterm's "application cursor / normal mode" default
/// (normal mode here — Claude/Codex don't request application cursor).
/// References: xterm ctlseqs, `infocmp xterm-256color`.
struct TerminalKeymap {
    func bytes(for event: NSEvent) -> [UInt8] {
        let mods = event.modifierFlags
        let option = mods.contains(.option)
        let shift = mods.contains(.shift)

        // Raw virtual key codes — stable across locales.
        switch event.keyCode {
        // Editing keys.
        case 36, 76: return [0x0D]                    // Return / keypad Enter
        case 51:     return [0x7F]                    // Backspace
        case 117:    return [0x1B, 0x5B, 0x33, 0x7E]  // Delete forward (fn+Del)
        case 53:     return [0x1B]                    // Escape
        case 48:     return [0x09]                    // Tab
        // Arrows. Option+arrow sends word-movement (xterm alt sequences).
        case 123:
            return option
                ? [0x1B, 0x62]                        // Option+Left = word-left (meta-b)
                : [0x1B, 0x5B, 0x44]                  // Left
        case 124:
            return option
                ? [0x1B, 0x66]                        // Option+Right = word-right (meta-f)
                : [0x1B, 0x5B, 0x43]                  // Right
        case 125:    return [0x1B, 0x5B, 0x42]        // Down
        case 126:    return [0x1B, 0x5B, 0x41]        // Up
        // Navigation cluster (fn+arrow on Apple keyboards).
        case 115:    return [0x1B, 0x5B, 0x48]        // Home
        case 119:    return [0x1B, 0x5B, 0x46]        // End
        case 116:    return [0x1B, 0x5B, 0x35, 0x7E]  // PageUp
        case 121:    return [0x1B, 0x5B, 0x36, 0x7E]  // PageDown
        // Function keys. Apple layouts need Fn or the "Use F1..F12 as
        // standard" preference; when the app receives them their keyCodes
        // are these.
        case 122:    return [0x1B, 0x4F, 0x50]        // F1
        case 120:    return [0x1B, 0x4F, 0x51]        // F2
        case 99:     return [0x1B, 0x4F, 0x52]        // F3
        case 118:    return [0x1B, 0x4F, 0x53]        // F4
        case 96:     return [0x1B, 0x5B, 0x31, 0x35, 0x7E] // F5
        case 97:     return [0x1B, 0x5B, 0x31, 0x37, 0x7E] // F6
        case 98:     return [0x1B, 0x5B, 0x31, 0x38, 0x7E] // F7
        case 100:    return [0x1B, 0x5B, 0x31, 0x39, 0x7E] // F8
        case 101:    return [0x1B, 0x5B, 0x32, 0x30, 0x7E] // F9
        case 109:    return [0x1B, 0x5B, 0x32, 0x31, 0x7E] // F10
        case 103:    return [0x1B, 0x5B, 0x32, 0x33, 0x7E] // F11
        case 111:    return [0x1B, 0x5B, 0x32, 0x34, 0x7E] // F12
        default: break
        }

        // Shift+Tab is a common unbind target (e.g. shell completion back).
        if event.keyCode == 48 && shift {
            return [0x1B, 0x5B, 0x5A]
        }

        // Ctrl-<letter>: map A..Z/@ to 1..26/0. `charactersIgnoringModifiers`
        // preserves the physical key regardless of the keyboard layout.
        if mods.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           let first = chars.first,
           let ascii = first.asciiValue {
            let lower = ascii >= 0x60 ? ascii - 0x60 : (ascii >= 0x40 ? ascii - 0x40 : ascii)
            return [lower & 0x1F]
        }

        // Option+<letter> in Terminal.app defaults to Meta-prefixed (ESC
        // then the letter). Matches bash readline expectations.
        if option,
           let chars = event.charactersIgnoringModifiers,
           let first = chars.first,
           let ascii = first.asciiValue {
            return [0x1B, ascii]
        }

        if let text = event.characters {
            return Array(text.utf8)
        }
        return []
    }
}
