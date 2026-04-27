//! Terminal cell grid. Simple row-major `Vec<Cell>` addressed as
//! `cells[row * cols + col]`. Tracks dirty rows so Swift only uploads
//! changed cells to the GPU each frame.
//!
//! This intentionally avoids scrollback in Phase 1 — the PTY log file under
//! `/tmp/tado-ipc/sessions/<id>/log` is still the scrollback source of truth.
//! Metal rendering only needs the visible grid.

use std::cmp::min;
use std::collections::VecDeque;

/// One terminal cell. 16 bytes — compact enough that a 200×100 grid
/// (20 000 cells) is ~320 KB, fine for memcpy to Swift per frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Cell {
    /// Unicode scalar. 0 = blank cell.
    pub ch: u32,
    /// RGBA foreground. 0xRRGGBBAA.
    pub fg: u32,
    /// RGBA background. 0xRRGGBBAA.
    pub bg: u32,
    /// Packed attributes (bold, italic, underline, reverse, …).
    pub attrs: u32,
}

impl Cell {
    pub const BLANK: Cell = Cell {
        ch: b' ' as u32,
        fg: 0xE8E8E8FF,
        bg: 0x000000FF,
        attrs: 0,
    };
}

// Hand-rolled attribute flags (kept in sync with Swift side via cbindgen).
pub const ATTR_BOLD: u32 = 1 << 0;
pub const ATTR_ITALIC: u32 = 1 << 1;
pub const ATTR_UNDERLINE: u32 = 1 << 2;
pub const ATTR_REVERSE: u32 = 1 << 3;
pub const ATTR_STRIKETHROUGH: u32 = 1 << 4;
pub const ATTR_DIM: u32 = 1 << 5;
/// Left half of a 2-cell-wide glyph (CJK, some box-drawing). The
/// renderer extends this cell's quad to span two columns. Mutually
/// exclusive with ATTR_WIDE_FILLER on any cell.
pub const ATTR_WIDE: u32 = 1 << 6;
/// Right half of a 2-cell-wide glyph. `ch` is 0. Shader skips
/// rasterization for these cells — the WIDE-start quad already
/// covers the pixels.
pub const ATTR_WIDE_FILLER: u32 = 1 << 7;

/// Default 16-color ANSI palette — matches the gruvbox-flavored colors
/// `performer::ansi_color` / `ansi_bright_color` used before Phase 2.15,
/// so themes that don't set a palette look unchanged. Indices are
/// packed as `0xRRGGBBAA`.
pub const DEFAULT_ANSI_PALETTE: [u32; 16] = [
    // Normal (SGR 30..=37 fg / 40..=47 bg)
    0x000000FF, // 0 black
    0xCC241DFF, // 1 red
    0x98971AFF, // 2 green
    0xD79921FF, // 3 yellow
    0x458588FF, // 4 blue
    0xB16286FF, // 5 magenta
    0x689D6AFF, // 6 cyan
    0xEBDBB2FF, // 7 white
    // Bright (SGR 90..=97 fg / 100..=107 bg)
    0x928374FF, // 8  bright black
    0xFB4934FF, // 9  bright red
    0xB8BB26FF, // 10 bright green
    0xFABD2FFF, // 11 bright yellow
    0x83A598FF, // 12 bright blue
    0xD3869BFF, // 13 bright magenta
    0x8EC07CFF, // 14 bright cyan
    0xFBF1C7FF, // 15 bright white
];

/// Display width of a Unicode scalar in terminal cells. 0 for
/// combining / zero-width codepoints (skipped by `put_char`), 1 for
/// regular, 2 for East-Asian Wide + box-drawing wide variants. Wraps
/// the `unicode-width` crate so the mapping stays consistent with
/// other terminal emulators.
pub fn char_width(ch: char) -> u8 {
    use unicode_width::UnicodeWidthChar;
    ch.width().unwrap_or(1) as u8
}

pub struct Grid {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<Cell>,
    pub cursor_x: u16,
    pub cursor_y: u16,
    /// Per-row dirty flag. Cleared by `take_dirty()`; set by writes.
    pub dirty_rows: Vec<bool>,
    /// Default attributes applied by blank cells and `erase`.
    pub default_fg: u32,
    pub default_bg: u32,
    pub current_attrs: u32,
    pub current_fg: u32,
    pub current_bg: u32,
    /// Scrollback buffer — rows that fell off the top of the live grid.
    /// Each inner `Vec<Cell>` is exactly `cols` cells (snapshotted at the
    /// time of eviction; a subsequent resize won't reshape history).
    /// Oldest line at index 0, most-recently-evicted at `len-1`.
    pub scrollback: VecDeque<Vec<Cell>>,
    /// Hard cap — oldest lines are dropped when `scrollback.len() >= cap`.
    /// 5000 is ~2 MB of cell data for 80-col terminals and matches the
    /// default SwiftTerm scrollback; tune via `set_scrollback_cap`.
    pub scrollback_cap: usize,

    /// Ring buffer of full-grid snapshots captured over time. Serves as
    /// a "tape recorder" scrollback for TUIs (Claude Code, Codex, vim)
    /// that paint via cursor positioning rather than newline scrolling —
    /// traditional line-based scrollback stays empty for those sessions,
    /// but every captured frame here is a complete record of what the
    /// tile displayed at that moment. Capture is driven from Swift
    /// (`capture_viewport_frame`) so the cadence matches the render
    /// loop without burning idle cycles.
    ///
    /// Each entry is a `cols*rows` cell buffer — oldest at index 0,
    /// newest at `len-1`. Layout intentionally mirrors `self.cells` so
    /// `viewport_frame_snapshot` can hand the Metal renderer the same
    /// shape as a regular full snapshot.
    pub viewport_history: VecDeque<Vec<Cell>>,
    /// Hard cap on `viewport_history`. 400 frames × (80*24 cells ×
    /// 16 B) ≈ 12 MB per tile in the worst case; at ~2 fps capture
    /// cadence that's ~3 minutes of scrubbable history. Tunable via
    /// `set_viewport_history_cap`.
    pub viewport_history_cap: usize,
    /// (cols, rows) the snapshots in `viewport_history` were captured
    /// at. A resize drops history because the old frame shape doesn't
    /// compose with the new grid.
    viewport_history_shape: (u16, u16),
    /// DECSET 25 — cursor visibility. TUIs hide the cursor during render
    /// to prevent flicker. Consumed by the Metal renderer.
    pub cursor_visible: bool,
    /// DECSET 2004 — bracketed paste mode. When true, the terminal wraps
    /// pasted text with `ESC [ 200 ~` / `ESC [ 201 ~` so the shell can
    /// distinguish a paste from typed input. Read by the Swift paste
    /// handler.
    pub bracketed_paste: bool,
    /// DECSET 1000 — X11 mouse button reporting (press + release).
    pub mouse_reporting_button: bool,
    /// DECSET 1002 — button-event tracking (button + drag).
    pub mouse_reporting_drag: bool,
    /// DECSET 1006 — SGR extended mouse coordinates. Preferred for
    /// modern apps since it supports columns > 95.
    pub mouse_reporting_sgr: bool,
    /// DECSET 1 (DECCKM) — application cursor mode. When true, arrow
    /// keys emit SS3-prefixed sequences (ESC O A) instead of the
    /// default CSI-prefixed (ESC [ A). vim and less flip this on when
    /// entering alt-screen so their custom keybindings can distinguish
    /// arrow presses from escape sequences.
    pub application_cursor: bool,
    /// 16-slot ANSI palette keyed by SGR code. Indices 0..=7 are the
    /// "normal" colors (SGR 30..=37 fg, 40..=47 bg), 8..=15 are the
    /// "bright" colors (SGR 90..=97 fg, 100..=107 bg). Swift-side themes
    /// can override via `set_ansi_palette` so a session picked with
    /// Solarized looks Solarized for colored output too, not just
    /// blank bg/fg.
    pub ansi_palette: [u32; 16],
    /// Saved cursor (DECSC / CSI s). Stored as (x, y, attrs) so colored
    /// segments restore correctly. None until first save.
    pub saved_cursor: Option<(u16, u16, u32, u32, u32)>,
    /// Top and bottom of the scrolling region (DECSTBM). Inclusive;
    /// default is 0..rows-1 (whole screen).
    pub scroll_top: u16,
    pub scroll_bottom: u16,
    /// Alternate screen buffer (DECSET 1049/1047). Vim, less, htop, and
    /// `claude` fullscreen all flip into this so the user's shell prompt
    /// is preserved. `None` when on the primary screen.
    alt_screen: Option<Box<AltScreenState>>,
}

/// What we stash when entering the alternate screen. Owned via `Box` so
/// `Grid`'s size stays small for the 99% case (no alt-screen).
struct AltScreenState {
    cells: Vec<Cell>,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: bool,
    current_attrs: u32,
    current_fg: u32,
    current_bg: u32,
    /// Whether the saved buffer was the primary (we restore it on exit).
    /// Always true today; kept for future symmetry when supporting other
    /// DECSET variants.
    #[allow(dead_code)]
    is_primary: bool,
}

impl Grid {
    pub fn new(cols: u16, rows: u16) -> Self {
        let len = (cols as usize) * (rows as usize);
        Self {
            cols,
            rows,
            cells: vec![Cell::BLANK; len],
            cursor_x: 0,
            cursor_y: 0,
            dirty_rows: vec![true; rows as usize],
            default_fg: Cell::BLANK.fg,
            default_bg: Cell::BLANK.bg,
            current_attrs: 0,
            current_fg: Cell::BLANK.fg,
            current_bg: Cell::BLANK.bg,
            scrollback: VecDeque::new(),
            scrollback_cap: 5000,
            viewport_history: VecDeque::new(),
            viewport_history_cap: 400,
            viewport_history_shape: (cols, rows),
            cursor_visible: true,
            saved_cursor: None,
            scroll_top: 0,
            scroll_bottom: rows.saturating_sub(1),
            alt_screen: None,
            bracketed_paste: false,
            mouse_reporting_button: false,
            mouse_reporting_drag: false,
            mouse_reporting_sgr: false,
            application_cursor: false,
            ansi_palette: DEFAULT_ANSI_PALETTE,
        }
    }

    /// Replace the 16-slot ANSI palette. Expects `rgba[0..8]` normal,
    /// `rgba[8..16]` bright. Pass `DEFAULT_ANSI_PALETTE` to restore the
    /// built-in gruvbox-flavored default. Mutates the grid's active
    /// palette; in-flight SGR chars retain their previously-resolved
    /// colors so a mid-stream palette swap doesn't retint existing
    /// text.
    pub fn set_ansi_palette(&mut self, palette: [u32; 16]) {
        self.ansi_palette = palette;
    }

    /// DECSC / CSI s — save cursor position + current SGR attrs.
    pub fn save_cursor(&mut self) {
        self.saved_cursor = Some((
            self.cursor_x,
            self.cursor_y,
            self.current_attrs,
            self.current_fg,
            self.current_bg,
        ));
    }

    /// DECRC / CSI u — restore saved cursor. No-op if never saved.
    pub fn restore_cursor(&mut self) {
        if let Some((x, y, attrs, fg, bg)) = self.saved_cursor {
            self.cursor_x = x.min(self.cols.saturating_sub(1));
            self.cursor_y = y.min(self.rows.saturating_sub(1));
            self.current_attrs = attrs;
            self.current_fg = fg;
            self.current_bg = bg;
        }
    }

    /// DECSTBM — set scrolling region `[top, bottom]`, clamped to grid.
    /// CSI takes 1-indexed args; callers should subtract 1.
    pub fn set_scroll_region(&mut self, top: u16, bottom: u16) {
        let max_row = self.rows.saturating_sub(1);
        self.scroll_top = top.min(max_row);
        self.scroll_bottom = bottom.min(max_row).max(self.scroll_top);
        // Per VT100, DECSTBM also homes the cursor.
        self.cursor_x = 0;
        self.cursor_y = self.scroll_top;
    }

    /// DECSET 1049 / 1047 — switch to the alternate screen and stash the
    /// primary. Re-entering is a no-op (already on alt).
    pub fn enter_alt_screen(&mut self) {
        if self.alt_screen.is_some() {
            return;
        }
        self.alt_screen = Some(Box::new(AltScreenState {
            cells: std::mem::replace(
                &mut self.cells,
                vec![Cell::BLANK; (self.cols as usize) * (self.rows as usize)],
            ),
            cursor_x: self.cursor_x,
            cursor_y: self.cursor_y,
            cursor_visible: self.cursor_visible,
            current_attrs: self.current_attrs,
            current_fg: self.current_fg,
            current_bg: self.current_bg,
            is_primary: true,
        }));
        self.cursor_x = 0;
        self.cursor_y = 0;
        for d in self.dirty_rows.iter_mut() {
            *d = true;
        }
    }

    /// DECRST 1049 / 1047 — restore the primary screen. No-op when
    /// already on primary.
    pub fn leave_alt_screen(&mut self) {
        let Some(saved) = self.alt_screen.take() else {
            return;
        };
        if saved.cells.len() == self.cells.len() {
            self.cells = saved.cells;
        } else {
            // Primary was sized differently — blank to new size rather than
            // show garbled geometry.
            self.cells =
                vec![Cell::BLANK; (self.cols as usize) * (self.rows as usize)];
        }
        self.cursor_x = saved.cursor_x.min(self.cols.saturating_sub(1));
        self.cursor_y = saved.cursor_y.min(self.rows.saturating_sub(1));
        self.cursor_visible = saved.cursor_visible;
        self.current_attrs = saved.current_attrs;
        self.current_fg = saved.current_fg;
        self.current_bg = saved.current_bg;
        for d in self.dirty_rows.iter_mut() {
            *d = true;
        }
    }

    pub fn is_alt_screen(&self) -> bool {
        self.alt_screen.is_some()
    }

    pub fn set_scrollback_cap(&mut self, cap: usize) {
        self.scrollback_cap = cap;
        while self.scrollback.len() > cap {
            self.scrollback.pop_front();
        }
    }

    /// Push a copy of the current grid into `viewport_history`, evicting
    /// the oldest frame once the cap is reached. Callers drive the
    /// cadence from Swift (typically ~2 fps) so idle tiles don't pad
    /// history with duplicate frames and animation-heavy tiles don't
    /// drown storage either. Shape changes (resize) clear history first
    /// — rendering a mismatched-shape frame would look corrupted.
    pub fn capture_viewport_frame(&mut self) {
        let shape = (self.cols, self.rows);
        if shape != self.viewport_history_shape {
            self.viewport_history.clear();
            self.viewport_history_shape = shape;
        }
        // Don't record anything while alt-screen is active — those
        // frames show the TUI's transient buffer (e.g., vim while
        // editing) and would clutter scrollback with garbage between
        // the primary-screen frames users actually want to revisit.
        if self.alt_screen.is_some() {
            return;
        }
        self.viewport_history.push_back(self.cells.clone());
        while self.viewport_history.len() > self.viewport_history_cap {
            self.viewport_history.pop_front();
        }
    }

    pub fn set_viewport_history_cap(&mut self, cap: usize) {
        self.viewport_history_cap = cap;
        while self.viewport_history.len() > cap {
            self.viewport_history.pop_front();
        }
    }

    /// Copy the viewport frame `offset` steps back from the newest into a
    /// freshly allocated `Vec<Cell>`. `offset = 1` is "one capture ago",
    /// `offset = 0` means "return the newest frame" (rarely useful —
    /// the caller almost always wants the live grid there instead).
    /// Returns `None` past the end of history.
    pub fn viewport_frame(&self, offset: usize) -> Option<Vec<Cell>> {
        if offset == 0 {
            return None;
        }
        let len = self.viewport_history.len();
        if offset > len {
            return None;
        }
        let idx = len - offset;
        self.viewport_history.get(idx).cloned()
    }

    pub fn viewport_frame_count(&self) -> usize {
        self.viewport_history.len()
    }

    /// Change the palette that blank / erased / SGR-reset cells pick up.
    /// Called from the Swift side when a tile's `TerminalTheme` changes.
    /// Also retints cells that are currently still in the "factory
    /// blank" state (space + old default fg/bg + attrs=0), so an
    /// immediately-themed newly-spawned tile shows themed background
    /// everywhere the agent hasn't yet written. Cells the agent has
    /// touched keep their explicit colors.
    pub fn set_default_colors(&mut self, fg: u32, bg: u32) {
        let old_fg = self.default_fg;
        let old_bg = self.default_bg;
        self.default_fg = fg;
        self.default_bg = bg;

        // Retrack the current SGR if it was still at the old defaults.
        if self.current_fg == old_fg {
            self.current_fg = fg;
        }
        if self.current_bg == old_bg {
            self.current_bg = bg;
        }

        // Retint "still-factory" cells. A cell is considered untouched
        // iff its ch+fg+bg+attrs match the old blank state. That covers
        // fresh grids + rows blanked by `erase` calls under the old
        // palette. Mark rows dirty so the renderer reuploads.
        let retint_from = Cell {
            ch: b' ' as u32,
            fg: old_fg,
            bg: old_bg,
            attrs: 0,
        };
        let retint_to = Cell {
            ch: b' ' as u32,
            fg,
            bg,
            attrs: 0,
        };
        let cols = self.cols as usize;
        for (i, cell) in self.cells.iter_mut().enumerate() {
            if *cell == retint_from {
                *cell = retint_to;
                let row = i / cols;
                if row < self.dirty_rows.len() {
                    self.dirty_rows[row] = true;
                }
            }
        }
    }

    /// Copy N historical rows into a flat `Vec<Cell>` (row-major, `cols`
    /// cells per row). `offset` counts from the most-recently-evicted line:
    /// offset 0 is the line that just fell off the top. Returns fewer rows
    /// than requested when the caller asks past the start of history.
    pub fn scrollback_snapshot(&self, offset: usize, rows: usize) -> Vec<Cell> {
        let total = self.scrollback.len();
        if offset >= total || rows == 0 {
            return Vec::new();
        }
        // Scrollback indexing: idx 0 = oldest, idx len-1 = newest.
        // `offset = 0` means newest → end of deque.
        let available = total - offset;
        let take = rows.min(available);
        let start_idx = total - offset - take;
        let mut out = Vec::with_capacity(take * self.cols as usize);
        for i in 0..take {
            if let Some(row) = self.scrollback.get(start_idx + i) {
                // Pad/truncate in case a past resize mismatched column count.
                let cols = self.cols as usize;
                if row.len() == cols {
                    out.extend_from_slice(row);
                } else if row.len() > cols {
                    out.extend_from_slice(&row[..cols]);
                } else {
                    out.extend_from_slice(row);
                    out.resize(out.len() + (cols - row.len()), Cell::BLANK);
                }
            }
        }
        out
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        if cols == self.cols && rows == self.rows {
            return;
        }
        let mut new = vec![Cell::BLANK; (cols as usize) * (rows as usize)];
        let copy_cols = min(self.cols, cols) as usize;
        let copy_rows = min(self.rows, rows) as usize;
        for r in 0..copy_rows {
            let src = r * self.cols as usize;
            let dst = r * cols as usize;
            new[dst..dst + copy_cols].copy_from_slice(&self.cells[src..src + copy_cols]);
        }
        self.cols = cols;
        self.rows = rows;
        self.cells = new;
        self.cursor_x = min(self.cursor_x, cols.saturating_sub(1));
        self.cursor_y = min(self.cursor_y, rows.saturating_sub(1));
        self.dirty_rows = vec![true; rows as usize];

        // Reset the scrolling region to full-screen on resize. Programs
        // rely on this — per VT100, any DECSTBM survives until cleared,
        // but physical resize implies a new geometry.
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);

        // Drop any alt-screen buffer — its geometry is stale. Programs
        // running in alt-screen re-render on SIGWINCH.
        self.alt_screen = None;
    }

    #[inline]
    fn idx(&self, x: u16, y: u16) -> usize {
        (y as usize) * (self.cols as usize) + (x as usize)
    }

    pub fn put_char(&mut self, ch: char) {
        let w = char_width(ch);
        // Zero-width codepoints (combining marks, ZWJ, BOM…) are routed
        // separately by `GridPerformer::print` via `compose_combining`.
        // Reaching `put_char` with width 0 would be a programming error;
        // silently drop as a defensive guard so a stray caller can't
        // corrupt the cursor position.
        if w == 0 {
            return;
        }
        // Wide glyph needs two cells, so wrap when only one cell
        // remains on the current row to avoid straddling the right
        // edge. Single-width glyphs only wrap once the cursor has
        // walked past the last column.
        if (w == 2 && self.cursor_x + 1 >= self.cols) || self.cursor_x >= self.cols {
            self.newline();
        }

        let i = self.idx(self.cursor_x, self.cursor_y);
        if w == 2 {
            self.cells[i] = Cell {
                ch: ch as u32,
                fg: self.current_fg,
                bg: self.current_bg,
                attrs: self.current_attrs | ATTR_WIDE,
            };
            // Right-half filler: ch=0 so the shader short-circuits;
            // ATTR_WIDE_FILLER tells the renderer to skip its quad.
            let j = self.idx(self.cursor_x + 1, self.cursor_y);
            self.cells[j] = Cell {
                ch: 0,
                fg: self.current_fg,
                bg: self.current_bg,
                attrs: ATTR_WIDE_FILLER,
            };
            self.cursor_x += 2;
        } else {
            self.cells[i] = Cell {
                ch: ch as u32,
                fg: self.current_fg,
                bg: self.current_bg,
                attrs: self.current_attrs,
            };
            self.cursor_x += 1;
        }
        self.dirty_rows[self.cursor_y as usize] = true;
    }

    /// Fold a width-0 combining character onto the previous cell's `ch`
    /// via NFC precomposition. Common case: `'a' + U+0301` → `'á'`.
    /// When no precomposed form exists in Unicode (e.g. `'a' + U+0332`,
    /// emoji + skin-tone modifier, ZWJ families), the mark is dropped.
    /// That matches the plan's "acceptable fallback: renders as individual
    /// glyphs" and beats the pre-2.21 behavior of dropping every width-0
    /// codepoint regardless.
    ///
    /// Called by `GridPerformer::print` when `unicode_width` reports the
    /// character has width 0. The cursor does NOT advance — combining
    /// marks glue onto the prior glyph, they don't consume a cell.
    pub fn compose_combining(&mut self, c: char) {
        // Resolve the target cell (the one holding the base character).
        // Normally that's the cell immediately to the left of the cursor.
        // If the cursor has already wrapped to the next row (no cells to
        // the left on the current row), walk back to the rightmost
        // non-filler cell of the previous row.
        let (tx, ty) = if self.cursor_x > 0 {
            (self.cursor_x - 1, self.cursor_y)
        } else if self.cursor_y > 0 {
            let y = self.cursor_y - 1;
            let mut x = self.cols.saturating_sub(1);
            // Skip the trailing half of a wide glyph so we compose onto
            // the wide-start cell (the one with the actual ch, not 0).
            while x > 0 {
                let idx = self.idx(x, y);
                if self.cells[idx].attrs & ATTR_WIDE_FILLER == 0 {
                    break;
                }
                x -= 1;
            }
            (x, y)
        } else {
            // Cursor at (0, 0) with nothing written yet — no base to
            // compose onto. Drop.
            return;
        };

        let idx = self.idx(tx, ty);
        let prev_ch = match char::from_u32(self.cells[idx].ch) {
            Some(ch) if ch != '\0' => ch,
            _ => return, // blank cell — nothing to compose onto
        };

        if let Some(composed) = crate::composition::compose(prev_ch, c) {
            self.cells[idx].ch = composed as u32;
            if (ty as usize) < self.dirty_rows.len() {
                self.dirty_rows[ty as usize] = true;
            }
        }
        // NFC miss: drop. Side-table + renderer overlay is future work.
    }

    pub fn backspace(&mut self) {
        if self.cursor_x > 0 {
            self.cursor_x -= 1;
        }
    }

    pub fn carriage_return(&mut self) {
        self.cursor_x = 0;
    }

    pub fn linefeed(&mut self) {
        // Respect the scrolling region (DECSTBM). When the cursor is at the
        // bottom of the region, scroll the region up; outside the region,
        // behave like a normal linefeed within the grid.
        if self.cursor_y == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor_y + 1 < self.rows {
            self.cursor_y += 1;
        }
    }

    pub fn newline(&mut self) {
        self.carriage_return();
        self.linefeed();
    }

    pub fn scroll_up(&mut self, n: u16) {
        // Scrolling is always bounded by the current DECSTBM region.
        // When the region spans the whole grid (default), this degrades
        // to the original full-grid scroll + scrollback push.
        let top = self.scroll_top as usize;
        let bot = self.scroll_bottom as usize;
        let region_rows = bot.saturating_sub(top) + 1;
        let n = min(n as usize, region_rows);
        if n == 0 {
            return;
        }
        let cols = self.cols as usize;
        let region_start = top * cols;
        let region_end = (bot + 1) * cols;

        // Only push to scrollback when we're on the primary screen AND the
        // whole grid is the scroll region. DECSTBM-bounded scrolls within
        // vim/less shouldn't pollute history, and alt-screen never should.
        let push_scrollback = self.alt_screen.is_none()
            && self.scroll_top == 0
            && self.scroll_bottom == self.rows.saturating_sub(1);
        if push_scrollback {
            for r in 0..n {
                let start = (top + r) * cols;
                let end = start + cols;
                let row: Vec<Cell> = self.cells[start..end].to_vec();
                self.scrollback.push_back(row);
                while self.scrollback.len() > self.scrollback_cap {
                    self.scrollback.pop_front();
                }
            }
        }

        // Shift rows within the region up by `n`.
        self.cells
            .copy_within((region_start + n * cols)..region_end, region_start);
        // Blank the bottom `n` rows of the region.
        let blank_from = region_end - n * cols;
        for c in self.cells[blank_from..region_end].iter_mut() {
            *c = Cell {
                ch: b' ' as u32,
                fg: self.default_fg,
                bg: self.default_bg,
                attrs: 0,
            };
        }
        // Only mark region rows dirty — faster per-frame upload.
        for r in top..=bot {
            if r < self.dirty_rows.len() {
                self.dirty_rows[r] = true;
            }
        }
    }

    pub fn move_cursor(&mut self, x: u16, y: u16) {
        self.cursor_x = min(x, self.cols.saturating_sub(1));
        self.cursor_y = min(y, self.rows.saturating_sub(1));
    }

    pub fn erase_display(&mut self) {
        for c in self.cells.iter_mut() {
            *c = Cell {
                ch: b' ' as u32,
                fg: self.default_fg,
                bg: self.default_bg,
                attrs: 0,
            };
        }
        for d in self.dirty_rows.iter_mut() {
            *d = true;
        }
    }

    pub fn erase_line_from_cursor(&mut self) {
        let start = self.idx(self.cursor_x, self.cursor_y);
        let end = self.idx(0, self.cursor_y) + self.cols as usize;
        for c in self.cells[start..end].iter_mut() {
            *c = Cell {
                ch: b' ' as u32,
                fg: self.default_fg,
                bg: self.default_bg,
                attrs: 0,
            };
        }
        self.dirty_rows[self.cursor_y as usize] = true;
    }

    pub fn take_dirty(&mut self) -> Vec<u16> {
        let mut out = Vec::new();
        for (i, d) in self.dirty_rows.iter_mut().enumerate() {
            if *d {
                out.push(i as u16);
                *d = false;
            }
        }
        out
    }
}

#[cfg(test)]
mod scrollback_tests {
    use super::*;

    /// Helper: fill row `r` with ASCII `c`.
    fn fill_row(grid: &mut Grid, r: u16, c: u8) {
        let cols = grid.cols as usize;
        let start = r as usize * cols;
        for i in 0..cols {
            grid.cells[start + i].ch = c as u32;
        }
    }

    #[test]
    fn scroll_up_pushes_to_scrollback() {
        let mut g = Grid::new(4, 3);
        fill_row(&mut g, 0, b'a');
        fill_row(&mut g, 1, b'b');
        fill_row(&mut g, 2, b'c');
        g.scroll_up(1);
        assert_eq!(g.scrollback.len(), 1);
        assert_eq!(g.scrollback[0][0].ch, b'a' as u32);
    }

    #[test]
    fn scroll_up_many_preserves_order() {
        let mut g = Grid::new(4, 2);
        for i in 0..5 {
            fill_row(&mut g, 0, b'a' + i);
            g.scroll_up(1);
        }
        // Scrollback should be a..e in insertion order (oldest first).
        assert_eq!(g.scrollback.len(), 5);
        for (i, row) in g.scrollback.iter().enumerate() {
            assert_eq!(row[0].ch, (b'a' + i as u8) as u32);
        }
    }

    #[test]
    fn scrollback_respects_cap() {
        let mut g = Grid::new(4, 2);
        g.set_scrollback_cap(3);
        for i in 0..10 {
            fill_row(&mut g, 0, b'a' + i);
            g.scroll_up(1);
        }
        // Only the three most-recent evictions should survive.
        assert_eq!(g.scrollback.len(), 3);
        assert_eq!(g.scrollback[0][0].ch, b'h' as u32);
        assert_eq!(g.scrollback[2][0].ch, b'j' as u32);
    }

    #[test]
    fn scrollback_snapshot_returns_newest_at_offset_zero() {
        let mut g = Grid::new(4, 2);
        for i in 0..4 {
            fill_row(&mut g, 0, b'a' + i);
            g.scroll_up(1);
        }
        // offset=0, rows=2 → the two most-recent evictions (c, d).
        let snap = g.scrollback_snapshot(0, 2);
        assert_eq!(snap.len(), 8); // 2 rows * 4 cols
        assert_eq!(snap[0].ch, b'c' as u32);
        assert_eq!(snap[4].ch, b'd' as u32);
    }

    #[test]
    fn scrollback_snapshot_clamps_past_history() {
        let mut g = Grid::new(2, 2);
        fill_row(&mut g, 0, b'x');
        g.scroll_up(1);
        let snap = g.scrollback_snapshot(0, 10);
        assert_eq!(snap.len(), 2); // only 1 row of history, 2 cols
    }

    #[test]
    fn capture_viewport_frame_snapshots_current_cells() {
        let mut g = Grid::new(2, 2);
        fill_row(&mut g, 0, b'a');
        fill_row(&mut g, 1, b'b');
        g.capture_viewport_frame();
        assert_eq!(g.viewport_frame_count(), 1);
        // Mutating cells after capture must not change the captured frame.
        fill_row(&mut g, 0, b'z');
        let frame = g.viewport_frame(1).expect("frame exists");
        assert_eq!(frame[0].ch, b'a' as u32);
    }

    #[test]
    fn viewport_frame_offset_indexes_back_in_time() {
        let mut g = Grid::new(2, 1);
        for i in 0..4 {
            fill_row(&mut g, 0, b'a' + i);
            g.capture_viewport_frame();
        }
        // Newest is "d" at offset 1, oldest is "a" at offset 4.
        assert_eq!(g.viewport_frame(1).unwrap()[0].ch, b'd' as u32);
        assert_eq!(g.viewport_frame(2).unwrap()[0].ch, b'c' as u32);
        assert_eq!(g.viewport_frame(4).unwrap()[0].ch, b'a' as u32);
        assert!(g.viewport_frame(5).is_none());
        assert!(g.viewport_frame(0).is_none());
    }

    #[test]
    fn viewport_history_respects_cap() {
        let mut g = Grid::new(2, 1);
        g.set_viewport_history_cap(3);
        for i in 0..10 {
            fill_row(&mut g, 0, b'a' + i);
            g.capture_viewport_frame();
        }
        assert_eq!(g.viewport_frame_count(), 3);
        // The three most-recent captures survived (h, i, j).
        assert_eq!(g.viewport_frame(1).unwrap()[0].ch, b'j' as u32);
        assert_eq!(g.viewport_frame(3).unwrap()[0].ch, b'h' as u32);
    }

    #[test]
    fn viewport_history_clears_on_shape_change() {
        let mut g = Grid::new(2, 1);
        fill_row(&mut g, 0, b'x');
        g.capture_viewport_frame();
        assert_eq!(g.viewport_frame_count(), 1);
        g.resize(4, 2);
        // Next capture detects the shape mismatch and clears first.
        g.capture_viewport_frame();
        assert_eq!(g.viewport_frame_count(), 1);
        // The surviving capture has the new shape (4*2 = 8 cells).
        assert_eq!(g.viewport_frame(1).unwrap().len(), 8);
    }
}
