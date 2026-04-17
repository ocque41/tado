//! A single terminal session: spawns a PTY, runs a reader thread that feeds
//! a `vte::Parser` → `GridPerformer`, and exposes a snapshot API for the GPU
//! renderer and a write API for keystrokes.
//!
//! Thread model:
//! - One OS thread per session reads from the PTY master and feeds the
//!   `Grid` under a `parking_lot::Mutex`. Snapshots also lock briefly, but
//!   copies are scoped so lock contention is negligible.
//! - Writes from Swift go straight to the master writer (locked separately).
//!
//! This is O(sessions) OS threads. For the 100-tile target that's 100
//! threads; still well within macOS limits (typical default ulimit is 2048)
//! and cheaper than a tokio runtime here because PTY reads block on syscalls
//! that tokio can't meaningfully async. A future refactor may move to
//! `kqueue`-based coalescing.

use crate::grid::Grid;
use crate::performer::GridPerformer;
use crate::pty::{spawn as spawn_pty, PtyHandles};
use parking_lot::Mutex;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;

pub struct Session {
    pub cols: u16,
    pub rows: u16,
    grid: Arc<Mutex<Grid>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: Arc<Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>>,
    master: Arc<Mutex<Option<Box<dyn portable_pty::MasterPty + Send>>>>,
    pub running: Arc<AtomicBool>,
    pub exit_code: Arc<AtomicI32>,
}

impl Session {
    pub fn spawn(
        cmd: &str,
        args: &[String],
        cwd: Option<&str>,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
    ) -> std::io::Result<Arc<Self>> {
        let PtyHandles {
            reader,
            writer,
            child,
            master,
        } = spawn_pty(cmd, args, cwd, env, cols, rows)?;

        let grid = Arc::new(Mutex::new(Grid::new(cols, rows)));
        let running = Arc::new(AtomicBool::new(true));
        let exit_code = Arc::new(AtomicI32::new(i32::MIN));

        let session = Arc::new(Self {
            cols,
            rows,
            grid: grid.clone(),
            writer: Arc::new(Mutex::new(writer)),
            child: Arc::new(Mutex::new(Some(child))),
            master: Arc::new(Mutex::new(Some(master))),
            running: running.clone(),
            exit_code: exit_code.clone(),
        });

        Self::start_reader(grid, reader, running.clone(), {
            let child = session.child.clone();
            let exit_code = exit_code.clone();
            let running = running.clone();
            move || {
                // Reader EOF → check child exit status once.
                let mut guard = child.lock();
                if let Some(c) = guard.as_mut() {
                    if let Ok(status) = c.wait() {
                        exit_code.store(status.exit_code() as i32, Ordering::SeqCst);
                    }
                }
                running.store(false, Ordering::SeqCst);
            }
        });

        Ok(session)
    }

    fn start_reader(
        grid: Arc<Mutex<Grid>>,
        mut reader: Box<dyn Read + Send>,
        running: Arc<AtomicBool>,
        on_eof: impl FnOnce() + Send + 'static,
    ) {
        thread::spawn(move || {
            let mut parser = vte::Parser::new();
            let mut buf = [0u8; 8 * 1024];
            loop {
                if !running.load(Ordering::Acquire) {
                    break;
                }
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let mut g = grid.lock();
                        let mut perf = GridPerformer::new(&mut g);
                        for b in &buf[..n] {
                            parser.advance(&mut perf, *b);
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            on_eof();
        });
    }

    pub fn write(&self, bytes: &[u8]) -> std::io::Result<usize> {
        let mut w = self.writer.lock();
        w.write_all(bytes)?;
        w.flush()?;
        Ok(bytes.len())
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        if let Some(master) = self.master.lock().as_mut() {
            let _ = master.resize(portable_pty::PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
        self.grid.lock().resize(cols, rows);
    }

    /// Copy the full grid out for an initial upload. Subsequent frames should
    /// use `snapshot_dirty` to minimize memcpy.
    pub fn snapshot_full(&self) -> GridSnapshot {
        let g = self.grid.lock();
        GridSnapshot {
            cols: g.cols,
            rows: g.rows,
            cursor_x: g.cursor_x,
            cursor_y: g.cursor_y,
            cells: g.cells.clone(),
            dirty_rows: (0..g.rows).collect(),
        }
    }

    pub fn snapshot_dirty(&self) -> GridSnapshot {
        let mut g = self.grid.lock();
        let dirty = g.take_dirty();
        let cols = g.cols;
        let rows = g.rows;
        let cursor_x = g.cursor_x;
        let cursor_y = g.cursor_y;
        let mut cells = Vec::with_capacity(dirty.len() * cols as usize);
        for &r in &dirty {
            let start = (r as usize) * (cols as usize);
            cells.extend_from_slice(&g.cells[start..start + cols as usize]);
        }
        GridSnapshot {
            cols,
            rows,
            cursor_x,
            cursor_y,
            cells,
            dirty_rows: dirty,
        }
    }

    /// Snapshot `rows` lines of scrollback starting at `offset` lines back
    /// from the most-recently-evicted line. `offset=0, rows=10` returns the
    /// ten most-recently-evicted rows (newest last).
    pub fn scrollback_snapshot(&self, offset: usize, rows: usize) -> ScrollbackSnapshot {
        let g = self.grid.lock();
        let cols = g.cols;
        let cells = g.scrollback_snapshot(offset, rows);
        let actual_rows = if cols == 0 {
            0
        } else {
            (cells.len() / cols as usize) as u16
        };
        ScrollbackSnapshot {
            cols,
            rows: actual_rows,
            cells,
            total_available: g.scrollback.len() as u32,
        }
    }

    pub fn kill(&self, signal: i32) {
        // portable_pty Child has a `kill()` but no signal selector on macOS in
        // the portable API; signal is advisory here. Reader thread notices EOF.
        if let Some(c) = self.child.lock().as_mut() {
            let _ = c.kill();
        }
        self.running.store(false, Ordering::SeqCst);
        let _ = signal; // reserved for future direct SIG delivery
    }
}

#[derive(Debug, Clone)]
pub struct ScrollbackSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<crate::grid::Cell>,
    /// Total number of scrollback lines currently buffered (for UI sizing).
    pub total_available: u32,
}

#[derive(Debug, Clone)]
pub struct GridSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    /// Flat list of cells: one row per entry in `dirty_rows`, in order.
    /// Each row contributes exactly `cols` cells.
    pub cells: Vec<crate::grid::Cell>,
    pub dirty_rows: Vec<u16>,
}
