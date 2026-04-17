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
    /// Cell metrics for the renderer. Default matches the historical
    /// 13pt SF Mono; callers forward `AppSettings.terminalFontSize`.
    var metrics: FontMetrics = FontMetrics.defaultMono()
    /// Background color used for the MTKView's clear color (letterboxing
    /// between cells and the view edge). Packed 0xRRGGBBAA. Default is
    /// pure black; MetalTerminalTileView passes the tile theme's bg.
    var clearRGBA: UInt32 = 0x000000FF
    /// Called on the main actor when the PTY produces any output this
    /// frame. Wire to `TerminalSession.markActivity()` so the forward-mode
    /// prompt queue drains identically to the SwiftTerm path.
    var onDirty: (() -> Void)? = nil
    /// Called roughly once per second when no output has arrived.
    /// Wire to `TerminalSession.checkIdle()`.
    var onIdleTick: (() -> Void)? = nil
    /// Called when the PTY emits an OSC 0 / OSC 2 title sequence.
    /// Typical wiring is `TerminalSession.title = $0`.
    var onTitleChange: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> TerminalMTKView {
        let view = TerminalMTKView(session: session, cols: cols, rows: rows, metrics: metrics)
        view.applyClearColor(rgba: clearRGBA)
        view.onDirty = onDirty
        view.onIdleTick = onIdleTick
        view.onTitleChange = onTitleChange
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.resizeIfNeeded(cols: cols, rows: rows)
        nsView.applyClearColor(rgba: clearRGBA)
        nsView.onDirty = onDirty
        nsView.onIdleTick = onIdleTick
        nsView.onTitleChange = onTitleChange
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

    // MARK: Selection state

    /// Active click-drag selection range. `start` is the cell under the
    /// initial mouseDown; `end` follows the cursor during drag and freezes
    /// on mouseUp. Nil means "no selection" — single-cell clicks still
    /// clear here so Cmd+C against nothing is a no-op.
    private var selectionStart: CellCoord?
    private var selectionEnd: CellCoord?

    // MARK: Activity detection hooks (wired by MetalTerminalTileView)

    var onDirty: (() -> Void)?
    var onIdleTick: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    private var lastIdleTick: TimeInterval = 0

    init(
        session: TadoCore.Session,
        cols: UInt16,
        rows: UInt16,
        metrics: FontMetrics = FontMetrics.defaultMono()
    ) {
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
                    metrics: metrics,
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

    /// Set the Metal clear color from a packed 0xRRGGBBAA. MTKView uses
    /// this for the uncovered region between cells and the view edge.
    /// Called from MetalTerminalView.updateNSView whenever the tile's
    /// theme changes (theme changes never happen today post-spawn but
    /// will once live-theme-switching lands).
    func applyClearColor(rgba: UInt32) {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >>  8) & 0xFF) / 255.0
        let a = Double( rgba        & 0xFF) / 255.0
        self.clearColor = MTLClearColorMake(r, g, b, a)
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
        // Begin a selection. A mouseDown that isn't followed by a
        // mouseDragged will be interpreted as "start + end at the same
        // cell" → zero-width selection cleared on next single click.
        // mouseDown itself doesn't report to PTY — mouseUp does, if the
        // selection ended up empty (classical terminal UX).
        if let cell = cellCoord(for: event) {
            selectionStart = cell
            selectionEnd = cell
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let cell = cellCoord(for: event) {
            // If we didn't get a valid mouseDown cell (e.g., click started
            // off-view then dragged in), begin the selection here.
            if selectionStart == nil {
                selectionStart = cell
            }
            selectionEnd = cell
        }
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Typing always snaps us back to live view — behaves like every
        // other terminal scrollback I've used.
        if scrollOffset != 0 {
            scrollOffset = 0
            scrollPixelAccumulator = 0
        }
        let bytes = keymap.bytes(for: event, applicationCursor: session.applicationCursor)
        if !bytes.isEmpty {
            session.write(bytes)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                paste(nil)
                return true
            case "c":
                copy(nil)
                return true
            default:
                return false
            }
        }
        keyDown(with: event)
        return true
    }

    /// Copy the current selection to the general pasteboard. No-op when
    /// selection is empty. Menu bar Edit → Copy also funnels here via
    /// the responder chain.
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// NSResponder paste action — reached via Cmd+V or Edit → Paste.
    /// `paste(_:)` isn't declared on NSView so this isn't an `override`;
    /// it's a selector exposed to the responder chain.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        if session.bracketedPasteEnabled {
            // Bracketed paste: ESC [ 200 ~ ... ESC [ 201 ~
            let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
            let end:   [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
            var bytes = start
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(contentsOf: end)
            session.write(bytes)
        } else {
            session.write(text: text)
        }
    }

    // MARK: - Mouse reporting

    override func mouseUp(with event: NSEvent) {
        // Zero-width selections (pure click, no drag) clear the highlight
        // AND pass the click through to the PTY when mouse reporting is
        // on. Non-empty drags stay selected; the PTY sees nothing.
        if let start = selectionStart, let end = selectionEnd, start == end {
            selectionStart = nil
            selectionEnd = nil
            reportMouse(event: event, button: 0, isPress: false)
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        reportMouse(event: event, button: 2, isPress: true)
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        reportMouse(event: event, button: 2, isPress: false)
        super.rightMouseUp(with: event)
    }

    /// Emit an xterm mouse sequence for a button press/release. No-op
    /// when the PTY hasn't enabled DECSET 1000/1002. SGR (1006) encoding
    /// is preferred; falls back to silent-drop when unavailable since
    /// the legacy 32-byte encoding can't represent columns > 95.
    private func reportMouse(event: NSEvent, button: Int, isPress: Bool) {
        guard session.mouseMode != .off,
              let renderer = renderer,
              session.mouseSgrEncoding else {
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        // AppKit y-origin is bottom; terminal rows count from top.
        let flippedY = max(0, bounds.height - local.y)
        let col = max(1, Int(local.x / renderer.metrics.cellWidth) + 1)
        let row = max(1, Int(flippedY / renderer.metrics.cellHeight) + 1)
        let btnCode = button // 0=left, 1=middle, 2=right
        // SGR: CSI < btn ; col ; row (M = press, m = release)
        let trailer: Character = isPress ? "M" : "m"
        let seq = "\u{1B}[<\(btnCode);\(col);\(row)\(trailer)"
        session.write(text: seq)
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
            // Drain OSC title events on the same cadence — titles change
            // rarely so once-per-second polling is fine. Keeps the Rust
            // event buffer from growing during OSC-heavy output.
            if let newTitle = session.takeTitle(), !newTitle.isEmpty {
                onTitleChange?(newTitle)
            }
            // Bells: agents ring BEL on notifications. We coalesce to
            // one NSBeep per drain so a spam doesn't turn into a
            // staccato. NSBeep honors the user's "play feedback" system
            // preference, so users who've silenced it pay no cost.
            if session.takeBellCount() > 0 {
                NSSound.beep()
            }
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

        // Pass selection (if any) through to the renderer. Normalized
        // to reading order so the shader can walk start→end per-row.
        if let sel = activeSelection {
            let (lo, hi) = normalized(sel.start, sel.end)
            renderer.setSelection(
                start: (col: lo.col, row: lo.row),
                end:   (col: hi.col, row: hi.row)
            )
        } else {
            renderer.setSelection(start: nil, end: nil)
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

// MARK: - Cell coordinate helpers + selection text

/// Zero-indexed cell location in a terminal grid. `col` advances left →
/// right, `row` advances top → bottom. Equatable so `start == end`
/// detects a zero-width selection (pure click).
struct CellCoord: Equatable {
    let col: Int
    let row: Int
}

extension TerminalMTKView {
    /// Map an NSEvent's location (window coords, y-up) to a cell
    /// coordinate. Returns nil if the renderer isn't ready or the click
    /// fell outside the grid region (between the last row and the view
    /// edge during letterboxing).
    func cellCoord(for event: NSEvent) -> CellCoord? {
        guard let renderer = renderer else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        // Flip y — NSView has origin bottom-left, grid has top-left.
        let flippedY = bounds.height - local.y
        let col = Int(local.x / renderer.metrics.cellWidth)
        let row = Int(flippedY / renderer.metrics.cellHeight)
        guard col >= 0, row >= 0, col < Int(cols), row < Int(rows) else {
            return nil
        }
        return CellCoord(col: col, row: row)
    }

    /// Current active selection as a pair of cell coords in drag order,
    /// or nil when no selection or a zero-width one (pure click).
    /// Exposed for the renderer hand-off.
    var activeSelection: (start: CellCoord, end: CellCoord)? {
        guard let s = selectionStart, let e = selectionEnd, s != e else { return nil }
        return (s, e)
    }

    /// Extract selected text from the live grid snapshot. Returns nil if
    /// the selection is empty (start == end) or unset.
    func selectedText() -> String? {
        guard let sel = activeSelection else { return nil }
        guard let snap = session.snapshotFull() else { return nil }
        let (lo, hi) = normalized(sel.start, sel.end)
        return TerminalTextExtractor.extract(from: snap, start: lo, end: hi)
    }

    /// Reorder the selection endpoints into reading order regardless of
    /// drag direction. Used both for text extraction and for passing a
    /// normalized range to the shader.
    func normalized(_ a: CellCoord, _ b: CellCoord) -> (CellCoord, CellCoord) {
        if a.row < b.row || (a.row == b.row && a.col <= b.col) {
            return (a, b)
        }
        return (b, a)
    }
}

/// Pure text extraction used by `TerminalMTKView.selectedText()`. Kept
/// `internal` + free-function-shaped so unit tests can exercise it with
/// synthetic snapshots rather than spinning up a live PTY.
enum TerminalTextExtractor {
    /// Walk the selected cells in reading order and return the text.
    /// `start` and `end` must already be normalized (reading order).
    /// Multi-row selections include the full width of middle rows;
    /// single-row selections clamp to the inclusive `start.col..end.col`
    /// range. Matches Terminal.app / iTerm conventions. Trailing
    /// whitespace on each row is trimmed before joining.
    static func extract(
        from snap: TadoCore.Snapshot,
        start: CellCoord,
        end: CellCoord
    ) -> String {
        let cols = Int(snap.cols)
        guard cols > 0, snap.rows > 0, start.row <= end.row else { return "" }

        var lines: [String] = []
        for r in start.row...end.row {
            let startCol = (r == start.row) ? start.col : 0
            let endCol = (r == end.row) ? end.col : cols - 1
            var line = ""
            if startCol <= endCol {
                for c in startCol...min(endCol, cols - 1) {
                    let idx = r * cols + c
                    guard idx < snap.cells.count else { break }
                    let cell = snap.cells[idx]
                    // Skip the right half of wide glyphs — they're a
                    // rendering-only filler; the wide-start cell already
                    // emitted the real character.
                    if (cell.attrs & MetalTerminalRenderer.Attr.wideFiller) != 0 {
                        continue
                    }
                    let ch = cell.ch
                    if ch == 0 {
                        line.append(" ")
                    } else if let scalar = Unicode.Scalar(ch) {
                        line.unicodeScalars.append(scalar)
                    }
                }
            }
            lines.append(line.trimmingTrailingWhitespace())
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    /// Trim trailing spaces — terminal rows are padded with spaces to
    /// the right edge, but paste targets almost always want the trimmed
    /// line. Matches Terminal.app / iTerm copy semantics.
    func trimmingTrailingWhitespace() -> String {
        var idx = endIndex
        while idx > startIndex {
            let prev = index(before: idx)
            if self[prev] == " " || self[prev] == "\t" {
                idx = prev
            } else {
                break
            }
        }
        return String(self[startIndex..<idx])
    }
}

/// Keymap translates `NSEvent` into the UTF-8 / ESC sequences a PTY
/// expects. Supports both normal (CSI) and application (SS3) cursor
/// modes; vim / less / readline flip DECCKM to distinguish arrows.
/// References: xterm ctlseqs, `infocmp xterm-256color`.
struct TerminalKeymap {
    func bytes(for event: NSEvent, applicationCursor: Bool = false) -> [UInt8] {
        let mods = event.modifierFlags
        let option = mods.contains(.option)
        let shift = mods.contains(.shift)

        // Cursor / Home / End are the only sequences DECCKM changes.
        // `\x1BO?` (SS3) in app mode, `\x1B[?` (CSI) in normal mode.
        let cursorPrefix: [UInt8] = applicationCursor
            ? [0x1B, 0x4F]  // ESC O
            : [0x1B, 0x5B]  // ESC [

        // Raw virtual key codes — stable across locales.
        switch event.keyCode {
        // Editing keys.
        case 36, 76: return [0x0D]                    // Return / keypad Enter
        case 51:     return [0x7F]                    // Backspace
        case 117:    return [0x1B, 0x5B, 0x33, 0x7E]  // Delete forward (fn+Del)
        case 53:     return [0x1B]                    // Escape
        case 48:     return [0x09]                    // Tab
        // Arrows. Option+arrow is word-movement (meta-b / meta-f) in
        // every mode; plain arrows swap CSI↔SS3 under DECCKM.
        case 123:
            return option
                ? [0x1B, 0x62]
                : cursorPrefix + [0x44]               // Left
        case 124:
            return option
                ? [0x1B, 0x66]
                : cursorPrefix + [0x43]               // Right
        case 125:    return cursorPrefix + [0x42]     // Down
        case 126:    return cursorPrefix + [0x41]     // Up
        // Navigation cluster (fn+arrow on Apple keyboards). Home/End
        // also track DECCKM; PgUp/PgDn don't.
        case 115:    return cursorPrefix + [0x48]     // Home
        case 119:    return cursorPrefix + [0x46]     // End
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
