import Foundation
import CTadoCore

/// Swift-side namespace for the Rust `tado-core` bindings.
///
/// `TadoCore.Session` wraps the opaque `TadoSession *` and is what Phase 1's
/// `TerminalManager` uses instead of `LocalProcessTerminalView.startProcess`.
/// Phase 2 replaces the `SwiftTerm`-backed rendering with a Metal view that
/// consumes `snapshotDirty()` each frame.
///
/// Threading: the underlying PTY reader runs on a Rust-owned OS thread, so
/// `snapshotDirty()` can be called from any thread. Writes are also
/// thread-safe (a `parking_lot::Mutex` inside the session guards the
/// writer). Swift callers that care about ordering should still serialize
/// their writes.
enum TadoCore {
    final class Session {
        fileprivate let handle: OpaquePointer

        init?(
            command: String,
            args: [String],
            cwd: String?,
            environment: [String: String],
            cols: UInt16,
            rows: UInt16
        ) {
            // Allocate C strings that outlive the `tado_session_spawn` call.
            // strdup returns UnsafeMutablePointer<CChar>!; wrap as UnsafePointer
            // to match the C signature.
            let argPointers: [UnsafePointer<CChar>?] = args.map { arg -> UnsafePointer<CChar>? in
                guard let p = strdup(arg) else { return nil }
                return UnsafePointer(p)
            }
            defer {
                for p in argPointers {
                    if let p = p { free(UnsafeMutableRawPointer(mutating: p)) }
                }
            }

            var envBoxes: [(UnsafePointer<CChar>?, UnsafePointer<CChar>?)] = []
            envBoxes.reserveCapacity(environment.count)
            for (k, v) in environment {
                let kp: UnsafePointer<CChar>? = strdup(k).map { UnsafePointer($0) }
                let vp: UnsafePointer<CChar>? = strdup(v).map { UnsafePointer($0) }
                envBoxes.append((kp, vp))
            }
            defer {
                for (k, v) in envBoxes {
                    if let k = k { free(UnsafeMutableRawPointer(mutating: k)) }
                    if let v = v { free(UnsafeMutableRawPointer(mutating: v)) }
                }
            }

            var envPairs = envBoxes.map { TadoEnvPair(key: $0.0, value: $0.1) }
            let envCount = envPairs.count
            let argCount = args.count

            let cmdPtr = strdup(command)
            defer { if let cmdPtr { free(cmdPtr) } }
            let cwdPtr: UnsafeMutablePointer<CChar>? = cwd.flatMap { strdup($0) }
            defer { if let cwdPtr { free(cwdPtr) } }

            let ptr = argPointers.withUnsafeBufferPointer { argBuf -> OpaquePointer? in
                envPairs.withUnsafeMutableBufferPointer { envBuf -> OpaquePointer? in
                    guard let raw = tado_session_spawn(
                        cmdPtr,
                        argBuf.baseAddress,
                        UInt(argCount),
                        cwdPtr,
                        envBuf.baseAddress,
                        UInt(envCount),
                        cols,
                        rows
                    ) else {
                        return nil
                    }
                    return OpaquePointer(raw)
                }
            }
            guard let ptr else { return nil }
            self.handle = ptr
        }

        deinit {
            tado_session_release(UnsafeMutablePointer(handle))
        }

        /// Write raw bytes to the PTY (typically keyboard input).
        @discardableResult
        func write(_ bytes: [UInt8]) -> Int {
            bytes.withUnsafeBufferPointer { buf in
                Int(tado_session_write(
                    UnsafeMutablePointer(handle),
                    buf.baseAddress,
                    UInt(buf.count)
                ))
            }
        }

        @discardableResult
        func write(text: String) -> Int {
            write(Array(text.utf8))
        }

        func resize(cols: UInt16, rows: UInt16) {
            tado_session_resize(UnsafeMutablePointer(handle), cols, rows)
        }

        /// Set the palette used for blank cells + SGR reset. RGBA packed
        /// as 0xRRGGBBAA. Typically called right after spawn with the
        /// tile's theme so freshly-cleared regions pick up the tile
        /// color instead of generic black/white.
        func setDefaultColors(fg: UInt32, bg: UInt32) {
            tado_session_set_default_colors(UnsafeMutablePointer(handle), fg, bg)
        }

        func kill(signal: Int32 = 15) {
            tado_session_kill(UnsafeMutablePointer(handle), signal)
        }

        var isRunning: Bool {
            tado_session_is_running(UnsafeMutablePointer(handle)) != 0
        }

        /// DECSET 2004 — the PTY wants paste events wrapped with
        /// `ESC [ 200 ~` / `ESC [ 201 ~`. Consulted from Cmd+V handler.
        var bracketedPasteEnabled: Bool {
            tado_session_bracketed_paste(UnsafeMutablePointer(handle)) != 0
        }

        enum MouseMode: UInt8 {
            case off = 0
            case button = 1
            case drag = 2
        }

        var mouseMode: MouseMode {
            MouseMode(rawValue: tado_session_mouse_mode(UnsafeMutablePointer(handle))) ?? .off
        }

        /// 1006 — SGR mouse encoding. Allows columns > 95 and avoids the
        /// legacy 32-byte-offset encoding's ambiguity.
        var mouseSgrEncoding: Bool {
            tado_session_mouse_sgr(UnsafeMutablePointer(handle)) != 0
        }

        /// Pull the latest OSC 0/2 title, if any emerged since the last
        /// drain. Nil = no new title. Intermediate titles during a burst
        /// are coalesced Rust-side to avoid thrashing SwiftUI.
        func takeTitle() -> String? {
            guard let cstr = tado_session_take_title(UnsafeMutablePointer(handle)) else {
                return nil
            }
            defer { tado_string_free(cstr) }
            return String(cString: cstr)
        }

        /// Snapshot just the rows that changed since the last snapshot. Cheap —
        /// intended to be called per Metal frame for every visible tile.
        func snapshotDirty() -> Snapshot? {
            guard let raw = tado_session_snapshot_dirty(UnsafeMutablePointer(handle)) else {
                return nil
            }
            return Snapshot(raw: OpaquePointer(raw))
        }

        /// Full-grid snapshot. Use on first render and after resize.
        func snapshotFull() -> Snapshot? {
            guard let raw = tado_session_snapshot_full(UnsafeMutablePointer(handle)) else {
                return nil
            }
            return Snapshot(raw: OpaquePointer(raw))
        }

        /// Snapshot `rows` lines of scrollback starting at `offset` lines
        /// back from the most-recently-evicted line. `offset = 0, rows = 10`
        /// returns the ten newest evicted rows (oldest → newest in the
        /// returned cells array).
        func scrollbackSnapshot(offset: Int, rows: Int) -> Scrollback? {
            guard offset >= 0, rows > 0 else { return nil }
            guard let raw = tado_session_scrollback(
                UnsafeMutablePointer(handle),
                UInt(offset),
                UInt(rows)
            ) else {
                return nil
            }
            return Scrollback(raw: OpaquePointer(raw))
        }
    }

    /// Cell packed for direct upload to a Metal vertex/instance buffer.
    /// Layout matches `TadoCell` in the Rust FFI and `struct Cell` in
    /// `tado_core::grid`. DO NOT reorder fields without updating both sides.
    struct Cell: Equatable {
        var ch: UInt32
        var fg: UInt32
        var bg: UInt32
        var attrs: UInt32
    }

    struct Snapshot {
        let cols: UInt16
        let rows: UInt16
        let cursorX: UInt16
        let cursorY: UInt16
        /// DECTCEM mirror — the renderer should hide the cursor when false.
        let cursorVisible: Bool
        let dirtyRows: [UInt16]
        /// One row of `cols` cells per entry in `dirtyRows`, flattened in
        /// row-major order. Length == `dirtyRows.count * cols`.
        let cells: [Cell]

        fileprivate init(raw: OpaquePointer) {
            let ptr = UnsafeMutablePointer<TadoSnapshot>(raw)
            defer { tado_snapshot_free(ptr) }

            self.cols = tado_snapshot_cols(ptr)
            self.rows = tado_snapshot_rows(ptr)
            self.cursorX = tado_snapshot_cursor_x(ptr)
            self.cursorY = tado_snapshot_cursor_y(ptr)
            self.cursorVisible = tado_snapshot_cursor_visible(ptr) != 0

            let dirtyCount = Int(tado_snapshot_dirty_row_count(ptr))
            if dirtyCount > 0, let dirtyPtr = tado_snapshot_dirty_rows(ptr) {
                self.dirtyRows = Array(UnsafeBufferPointer(start: dirtyPtr, count: dirtyCount))
            } else {
                self.dirtyRows = []
            }

            let cellCount = Int(tado_snapshot_cells_len(ptr))
            if cellCount > 0, let cellPtr = tado_snapshot_cells(ptr) {
                let typed = UnsafeRawPointer(cellPtr).assumingMemoryBound(to: Cell.self)
                self.cells = Array(UnsafeBufferPointer(start: typed, count: cellCount))
            } else {
                self.cells = []
            }
        }

        /// Synthetic snapshot factory for tests and non-PTY callers (e.g.,
        /// a placeholder tile rendered with an empty grid). Bypasses the
        /// Rust FFI entirely. `fill(col, row)` is invoked for each cell.
        static func synthetic(
            cols: UInt16,
            rows: UInt16,
            cursorX: UInt16 = 0,
            cursorY: UInt16 = 0,
            cursorVisible: Bool = true,
            fill: (Int, Int) -> Cell
        ) -> Snapshot {
            var cells: [Cell] = []
            cells.reserveCapacity(Int(cols) * Int(rows))
            for r in 0..<Int(rows) {
                for c in 0..<Int(cols) {
                    cells.append(fill(c, r))
                }
            }
            return Snapshot(
                cols: cols,
                rows: rows,
                cursorX: cursorX,
                cursorY: cursorY,
                cursorVisible: cursorVisible,
                dirtyRows: (0..<rows).map { $0 },
                cells: cells
            )
        }

        private init(
            cols: UInt16,
            rows: UInt16,
            cursorX: UInt16,
            cursorY: UInt16,
            cursorVisible: Bool,
            dirtyRows: [UInt16],
            cells: [Cell]
        ) {
            self.cols = cols
            self.rows = rows
            self.cursorX = cursorX
            self.cursorY = cursorY
            self.cursorVisible = cursorVisible
            self.dirtyRows = dirtyRows
            self.cells = cells
        }
    }

    /// Historical rows that fell off the top of the live grid. Distinct
    /// from `Snapshot` because scrollback has no cursor/dirty concept —
    /// it's a read-only window into the Rust-side `VecDeque<Vec<Cell>>`.
    struct Scrollback {
        let cols: UInt16
        let rows: UInt16
        /// Row-major flattened cells. Oldest row first; newest row last.
        let cells: [Cell]
        /// Total scrollback lines currently buffered in Rust. Useful for
        /// scrollbar thumb sizing regardless of the current window.
        let totalAvailable: UInt32

        fileprivate init(raw: OpaquePointer) {
            let ptr = UnsafeMutablePointer<TadoScrollback>(raw)
            defer { tado_scrollback_free(ptr) }

            self.cols = tado_scrollback_cols(ptr)
            self.rows = tado_scrollback_rows(ptr)
            self.totalAvailable = tado_scrollback_total_available(ptr)

            let cellCount = Int(tado_scrollback_cells_len(ptr))
            if cellCount > 0, let cellPtr = tado_scrollback_cells(ptr) {
                let typed = UnsafeRawPointer(cellPtr).assumingMemoryBound(to: Cell.self)
                self.cells = Array(UnsafeBufferPointer(start: typed, count: cellCount))
            } else {
                self.cells = []
            }
        }
    }
}
