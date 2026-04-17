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
        }
    }

    pub fn set_scrollback_cap(&mut self, cap: usize) {
        self.scrollback_cap = cap;
        while self.scrollback.len() > cap {
            self.scrollback.pop_front();
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
    }

    #[inline]
    fn idx(&self, x: u16, y: u16) -> usize {
        (y as usize) * (self.cols as usize) + (x as usize)
    }

    pub fn put_char(&mut self, ch: char) {
        if self.cursor_x >= self.cols {
            self.newline();
        }
        let i = self.idx(self.cursor_x, self.cursor_y);
        self.cells[i] = Cell {
            ch: ch as u32,
            fg: self.current_fg,
            bg: self.current_bg,
            attrs: self.current_attrs,
        };
        self.dirty_rows[self.cursor_y as usize] = true;
        self.cursor_x += 1;
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
        if self.cursor_y + 1 >= self.rows {
            self.scroll_up(1);
        } else {
            self.cursor_y += 1;
        }
    }

    pub fn newline(&mut self) {
        self.carriage_return();
        self.linefeed();
    }

    pub fn scroll_up(&mut self, n: u16) {
        let n = min(n as usize, self.rows as usize);
        if n == 0 {
            return;
        }
        let cols = self.cols as usize;
        let total = self.cells.len();

        // Push the top `n` rows into scrollback before they're overwritten.
        // Each pushed row is an owned snapshot so later resizes don't
        // invalidate history.
        for r in 0..n {
            let start = r * cols;
            let end = start + cols;
            let row: Vec<Cell> = self.cells[start..end].to_vec();
            self.scrollback.push_back(row);
            while self.scrollback.len() > self.scrollback_cap {
                self.scrollback.pop_front();
            }
        }

        self.cells.copy_within(n * cols..total, 0);
        let blank_from = (self.rows as usize - n) * cols;
        for c in self.cells[blank_from..].iter_mut() {
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
}
