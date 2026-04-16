//! Implements `vte::Perform` to drive a `Grid` from a raw PTY byte stream.
//!
//! Phase 1 scope: handles the subset of VT sequences that matter for modern
//! CLI output (printable text, CR/LF/BS/TAB, CSI cursor movement, basic SGR,
//! erase display/line). Rare sequences are silently dropped — Claude/Codex
//! output doesn't exercise them. The test suite pins the subset.

use crate::grid::{
    Grid, ATTR_BOLD, ATTR_DIM, ATTR_ITALIC, ATTR_REVERSE, ATTR_STRIKETHROUGH, ATTR_UNDERLINE,
};
use vte::{Params, Perform};

pub struct GridPerformer<'a> {
    pub grid: &'a mut Grid,
}

impl<'a> GridPerformer<'a> {
    pub fn new(grid: &'a mut Grid) -> Self {
        Self { grid }
    }
}

impl<'a> Perform for GridPerformer<'a> {
    fn print(&mut self, c: char) {
        self.grid.put_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' | 0x0B | 0x0C => self.grid.linefeed(),
            b'\r' => self.grid.carriage_return(),
            b'\x08' => self.grid.backspace(),
            b'\t' => {
                // Tab stops every 8 cols
                let next = (self.grid.cursor_x / 8 + 1) * 8;
                let target = next.min(self.grid.cols.saturating_sub(1));
                self.grid.cursor_x = target;
            }
            b'\x07' => { /* bell */ }
            _ => {}
        }
    }

    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}

    fn csi_dispatch(
        &mut self,
        params: &Params,
        _intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        // Flatten to u16 params. `vte` exposes Params as iterator of slices; we
        // take the first subparam of each semicolon-separated group.
        let p0 = first_or(params, 0, 0);
        let p1 = first_or(params, 1, 0);

        match action {
            // Cursor movement
            'A' => {
                // CUU: cursor up
                let n = p0.max(1);
                self.grid.cursor_y = self.grid.cursor_y.saturating_sub(n);
            }
            'B' => {
                // CUD: cursor down
                let n = p0.max(1);
                self.grid.cursor_y = (self.grid.cursor_y + n).min(self.grid.rows.saturating_sub(1));
            }
            'C' => {
                // CUF: cursor forward
                let n = p0.max(1);
                self.grid.cursor_x = (self.grid.cursor_x + n).min(self.grid.cols.saturating_sub(1));
            }
            'D' => {
                // CUB: cursor back
                let n = p0.max(1);
                self.grid.cursor_x = self.grid.cursor_x.saturating_sub(n);
            }
            'H' | 'f' => {
                // CUP: cursor position (row;col, 1-indexed)
                let row = p0.saturating_sub(1);
                let col = p1.saturating_sub(1);
                self.grid.move_cursor(col, row);
            }
            'J' => {
                // ED: erase in display (treat any variant as full erase for Phase 1)
                self.grid.erase_display();
            }
            'K' => {
                // EL: erase in line
                self.grid.erase_line_from_cursor();
            }
            'm' => {
                // SGR
                apply_sgr(self.grid, params);
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}
}

fn first_or(params: &Params, idx: usize, default: u16) -> u16 {
    params
        .iter()
        .nth(idx)
        .and_then(|group| group.first().copied())
        .filter(|v| *v != 0)
        .unwrap_or(default)
        .max(default)
}

fn apply_sgr(grid: &mut Grid, params: &Params) {
    let mut iter = params.iter().flat_map(|g| g.iter().copied());
    while let Some(p) = iter.next() {
        match p {
            0 => {
                grid.current_attrs = 0;
                grid.current_fg = grid.default_fg;
                grid.current_bg = grid.default_bg;
            }
            1 => grid.current_attrs |= ATTR_BOLD,
            2 => grid.current_attrs |= ATTR_DIM,
            3 => grid.current_attrs |= ATTR_ITALIC,
            4 => grid.current_attrs |= ATTR_UNDERLINE,
            7 => grid.current_attrs |= ATTR_REVERSE,
            9 => grid.current_attrs |= ATTR_STRIKETHROUGH,
            22 => grid.current_attrs &= !(ATTR_BOLD | ATTR_DIM),
            23 => grid.current_attrs &= !ATTR_ITALIC,
            24 => grid.current_attrs &= !ATTR_UNDERLINE,
            27 => grid.current_attrs &= !ATTR_REVERSE,
            29 => grid.current_attrs &= !ATTR_STRIKETHROUGH,
            30..=37 => grid.current_fg = ansi_color(p - 30),
            39 => grid.current_fg = grid.default_fg,
            40..=47 => grid.current_bg = ansi_color(p - 40),
            49 => grid.current_bg = grid.default_bg,
            90..=97 => grid.current_fg = ansi_bright_color(p - 90),
            100..=107 => grid.current_bg = ansi_bright_color(p - 100),
            38 => {
                // 24-bit or 256-color fg
                if let Some(c) = read_extended_color(&mut iter) {
                    grid.current_fg = c;
                }
            }
            48 => {
                if let Some(c) = read_extended_color(&mut iter) {
                    grid.current_bg = c;
                }
            }
            _ => {}
        }
    }
}

fn read_extended_color<I: Iterator<Item = u16>>(iter: &mut I) -> Option<u32> {
    match iter.next()? {
        2 => {
            let r = iter.next()? as u32;
            let g = iter.next()? as u32;
            let b = iter.next()? as u32;
            Some((r << 24) | (g << 16) | (b << 8) | 0xFF)
        }
        5 => {
            let idx = iter.next()? as u8;
            Some(xterm_256(idx))
        }
        _ => None,
    }
}

fn ansi_color(i: u16) -> u32 {
    // Tado-ish palette (approximates the existing SwiftTerm default theme).
    match i {
        0 => 0x000000FF, // black
        1 => 0xCC241DFF, // red
        2 => 0x98971AFF, // green
        3 => 0xD79921FF, // yellow
        4 => 0x458588FF, // blue
        5 => 0xB16286FF, // magenta
        6 => 0x689D6AFF, // cyan
        7 => 0xEBDBB2FF, // white
        _ => 0xE8E8E8FF,
    }
}

fn ansi_bright_color(i: u16) -> u32 {
    match i {
        0 => 0x928374FF,
        1 => 0xFB4934FF,
        2 => 0xB8BB26FF,
        3 => 0xFABD2FFF,
        4 => 0x83A598FF,
        5 => 0xD3869BFF,
        6 => 0x8EC07CFF,
        7 => 0xFBF1C7FF,
        _ => 0xFFFFFFFF,
    }
}

fn xterm_256(i: u8) -> u32 {
    // Reference encoding: 16 base colors, 6×6×6 cube, 24 greyscale.
    if i < 16 {
        return if i < 8 {
            ansi_color(i as u16)
        } else {
            ansi_bright_color((i - 8) as u16)
        };
    }
    if i < 232 {
        let n = i - 16;
        let r = (n / 36) % 6;
        let g = (n / 6) % 6;
        let b = n % 6;
        let step = |c: u8| if c == 0 { 0 } else { 55 + c * 40 };
        let rgb = (step(r) as u32) << 24 | (step(g) as u32) << 16 | (step(b) as u32) << 8 | 0xFF;
        return rgb;
    }
    let v = 8 + (i - 232) * 10;
    (v as u32) << 24 | (v as u32) << 16 | (v as u32) << 8 | 0xFF
}

#[cfg(test)]
mod tests {
    use super::*;
    use vte::Parser;

    fn feed(grid: &mut Grid, bytes: &[u8]) {
        let mut parser = Parser::new();
        let mut perf = GridPerformer::new(grid);
        for b in bytes {
            parser.advance(&mut perf, *b);
        }
    }

    #[test]
    fn prints_plain_text() {
        let mut g = Grid::new(10, 3);
        feed(&mut g, b"hi\r\nyo");
        assert_eq!(g.cells[0].ch, b'h' as u32);
        assert_eq!(g.cells[1].ch, b'i' as u32);
        assert_eq!(g.cells[10].ch, b'y' as u32);
        assert_eq!(g.cursor_y, 1);
        assert_eq!(g.cursor_x, 2);
    }

    #[test]
    fn handles_cursor_movement() {
        let mut g = Grid::new(10, 5);
        feed(&mut g, b"\x1b[3;5H"); // CUP to row 3 col 5 (1-indexed)
        assert_eq!(g.cursor_y, 2);
        assert_eq!(g.cursor_x, 4);
    }

    #[test]
    fn handles_sgr_fg() {
        let mut g = Grid::new(10, 3);
        feed(&mut g, b"\x1b[31mX\x1b[0mY");
        assert_eq!(g.cells[0].fg, 0xCC241DFF);
        assert_eq!(g.cells[1].fg, g.default_fg);
    }

    #[test]
    fn scrolls_on_overflow() {
        let mut g = Grid::new(4, 2);
        feed(&mut g, b"aaaa\r\nbbbb\r\ncccc");
        // first row should now contain 'b', second row 'c'
        assert_eq!(g.cells[0].ch, b'b' as u32);
        assert_eq!(g.cells[4].ch, b'c' as u32);
    }

    #[test]
    fn erase_display_clears_grid() {
        let mut g = Grid::new(4, 2);
        feed(&mut g, b"abcd\r\nefgh");
        feed(&mut g, b"\x1b[2J");
        for c in &g.cells {
            assert_eq!(c.ch, b' ' as u32);
        }
    }
}
