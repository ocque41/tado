//! Plain C FFI consumed by Swift. All functions are `extern "C"` and catch
//! Rust panics so a panic can't unwind across the ABI boundary.
//!
//! Memory rules:
//! - Caller never frees Rust-owned memory directly. `tado_session_release`
//!   drops a session. `tado_snapshot_free` drops a snapshot.
//! - Cell buffers returned in snapshots live as long as the snapshot handle
//!   and are read-only from Swift.
//! - Input strings/bytes from Swift are borrowed for the duration of the
//!   call only; Rust copies if it needs to retain.
//!
//! All `unsafe extern "C"` functions in this module share that contract,
//! so `clippy::missing_safety_doc` is suppressed file-wide rather than
//! repeating the same `# Safety` paragraph on every entry point.
#![allow(clippy::missing_safety_doc)]

use crate::grid::Cell;
use crate::session::{GridSnapshot, MouseReportingMode, ScrollbackSnapshot, Session};
use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::panic;
use std::ptr;
use std::sync::Arc;

thread_local! {
    /// Captures the most recent `tado_session_spawn` failure on the caller's
    /// thread. Populated on every error branch inside the spawn path — null
    /// cstrings, `Session::spawn` IO errors, and caught panics. Swift reads
    /// this via `tado_last_spawn_error()` right after a nil return, so the
    /// UI can show the real cause instead of the generic "pending" placeholder.
    static LAST_SPAWN_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn record_spawn_error(msg: impl Into<String>) {
    LAST_SPAWN_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(msg.into());
    });
}

#[repr(C)]
pub struct TadoSession {
    _priv: [u8; 0],
}

#[repr(C)]
pub struct TadoSnapshot {
    _priv: [u8; 0],
}

/// Key-value pair for env vars. Both strings must be null-terminated UTF-8.
#[repr(C)]
pub struct TadoEnvPair {
    pub key: *const c_char,
    pub value: *const c_char,
}

/// Raw cell view for the Swift side. Matches the layout of `grid::Cell`
/// exactly (same `#[repr(C)]`, same field order).
#[repr(C)]
pub struct TadoCell {
    pub ch: u32,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u32,
}

/// Opaque return: spawn a session. Returns null on failure.
///
/// # Safety
/// All pointers must point at valid null-terminated UTF-8 (or be null where
/// annotated below). `argv` and `env` arrays are read up to their counts.
#[no_mangle]
pub unsafe extern "C" fn tado_session_spawn(
    cmd: *const c_char,
    argv: *const *const c_char,
    argc: usize,
    cwd: *const c_char, // may be null
    env: *const TadoEnvPair,
    env_count: usize,
    cols: u16,
    rows: u16,
) -> *mut TadoSession {
    // Clear stale error on every call so a success after a prior failure
    // doesn't leave the old message visible.
    LAST_SPAWN_ERROR.with(|cell| cell.borrow_mut().take());

    let result = panic::catch_unwind(|| {
        let cmd = match cstr_to_owned(cmd) {
            Some(s) => s,
            None => {
                record_spawn_error("command string was null or not valid UTF-8");
                return ptr::null_mut();
            }
        };
        let mut args = Vec::with_capacity(argc);
        for i in 0..argc {
            let p = *argv.add(i);
            if let Some(s) = cstr_to_owned(p) {
                args.push(s);
            }
        }
        let cwd = cstr_to_owned(cwd);
        let mut env_vec = Vec::with_capacity(env_count);
        for i in 0..env_count {
            let pair = &*env.add(i);
            if let (Some(k), Some(v)) = (cstr_to_owned(pair.key), cstr_to_owned(pair.value)) {
                env_vec.push((k, v));
            }
        }
        match Session::spawn(&cmd, &args, cwd.as_deref(), &env_vec, cols, rows) {
            Ok(session) => Arc::into_raw(session) as *mut TadoSession,
            Err(e) => {
                record_spawn_error(format!(
                    "Session::spawn failed (cmd={:?}, args={:?}, cwd={:?}, env_count={}): {}",
                    cmd,
                    args,
                    cwd.as_deref(),
                    env_vec.len(),
                    e
                ));
                ptr::null_mut()
            }
        }
    });
    match result {
        Ok(ptr) => ptr,
        Err(payload) => {
            let msg = panic_payload_to_string(&payload);
            record_spawn_error(format!("panic in tado_session_spawn: {}", msg));
            ptr::null_mut()
        }
    }
}

/// Pull+clear the last spawn error recorded on the current thread. Returns
/// a malloc'd CString (caller frees with `tado_string_free`) or null if no
/// error is pending. Always called from Swift immediately after
/// `tado_session_spawn` returns null, so the thread-local-per-call contract
/// holds: the spawn call ran on this thread, so the error is here too.
#[no_mangle]
pub unsafe extern "C" fn tado_last_spawn_error() -> *mut c_char {
    let msg = LAST_SPAWN_ERROR.with(|cell| cell.borrow_mut().take());
    match msg {
        Some(s) => {
            let sanitized: Vec<u8> = s.into_bytes().into_iter().filter(|b| *b != 0).collect();
            match CString::new(sanitized) {
                Ok(c) => c.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

fn panic_payload_to_string(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic payload".to_string()
    }
}

/// Drop a session handle. Safe to call with null (no-op).
#[no_mangle]
pub unsafe extern "C" fn tado_session_release(session: *mut TadoSession) {
    if session.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        drop(Arc::from_raw(session as *const Session));
    });
}

/// Write raw bytes to the session's PTY (keyboard input). Returns bytes written,
/// or -1 on error.
#[no_mangle]
pub unsafe extern "C" fn tado_session_write(
    session: *mut TadoSession,
    bytes: *const u8,
    len: usize,
) -> isize {
    if session.is_null() || bytes.is_null() {
        return -1;
    }
    let result = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        let slice = std::slice::from_raw_parts(bytes, len);
        s.write(slice).map(|n| n as isize).unwrap_or(-1)
    });
    result.unwrap_or(-1)
}

/// Resize the PTY and grid.
#[no_mangle]
pub unsafe extern "C" fn tado_session_resize(session: *mut TadoSession, cols: u16, rows: u16) {
    if session.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.resize(cols, rows);
    });
}

/// Set the default fg/bg colors used for blank cells and after SGR
/// reset. RGBA is packed `0xRRGGBBAA` — same encoding as `TadoCell.fg/bg`.
#[no_mangle]
pub unsafe extern "C" fn tado_session_set_default_colors(
    session: *mut TadoSession,
    fg: u32,
    bg: u32,
) {
    if session.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.set_default_colors(fg, bg);
    });
}

/// Replace the 16-slot ANSI palette consulted by SGR 30..=37/40..=47
/// (normal, slots 0..=7) and 90..=97/100..=107 (bright, slots 8..=15).
/// `palette` must point to 16 `uint32_t` RGBA values. No-op on null.
#[no_mangle]
pub unsafe extern "C" fn tado_session_set_ansi_palette(
    session: *mut TadoSession,
    palette: *const u32,
) {
    if session.is_null() || palette.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        let mut copy = [0u32; 16];
        std::ptr::copy_nonoverlapping(palette, copy.as_mut_ptr(), 16);
        s.set_ansi_palette(copy);
    });
}

/// Kill the child process (SIGTERM-ish; exact semantics depend on OS).
#[no_mangle]
pub unsafe extern "C" fn tado_session_kill(session: *mut TadoSession, signal: i32) {
    if session.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.kill(signal);
    });
}

/// 1 if the child is still running, 0 otherwise.
#[no_mangle]
pub unsafe extern "C" fn tado_session_is_running(session: *mut TadoSession) -> u8 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.running
            .load(std::sync::atomic::Ordering::Acquire) as u8
    });
    r.unwrap_or(0)
}

/// 1 if the PTY has bracketed paste mode enabled (DECSET 2004).
#[no_mangle]
pub unsafe extern "C" fn tado_session_bracketed_paste(session: *mut TadoSession) -> u8 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.bracketed_paste() as u8
    });
    r.unwrap_or(0)
}

/// 1 if the PTY has DECCKM application cursor mode enabled (DECSET 1).
/// The Swift keymap reads this to emit SS3-prefixed arrows (ESC O A …)
/// instead of CSI-prefixed (ESC [ A …) when true.
#[no_mangle]
pub unsafe extern "C" fn tado_session_application_cursor(session: *mut TadoSession) -> u8 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.application_cursor() as u8
    });
    r.unwrap_or(0)
}

/// Mouse reporting mode: 0 off, 1 button, 2 drag. Use
/// `tado_session_mouse_sgr` to determine the encoding.
#[no_mangle]
pub unsafe extern "C" fn tado_session_mouse_mode(session: *mut TadoSession) -> u8 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        match s.mouse_reporting_mode() {
            MouseReportingMode::Off => 0u8,
            MouseReportingMode::Button => 1u8,
            MouseReportingMode::Drag => 2u8,
        }
    });
    r.unwrap_or(0)
}

/// 1 if the PTY uses SGR (1006) mouse encoding — modern, column-uncapped.
#[no_mangle]
pub unsafe extern "C" fn tado_session_mouse_sgr(session: *mut TadoSession) -> u8 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.mouse_reporting_sgr() as u8
    });
    r.unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Title events (OSC 0 / OSC 2)
// ---------------------------------------------------------------------------
//
// Rust accumulates GridEvents as bytes arrive. Swift drains them each
// draw-tick via `tado_session_take_title`. We return only the most
// recent title — intermediate updates during a burst are coalesced to
// avoid thrashing SwiftUI's observation.

/// Pull the latest title emitted since the last call. Returns a malloc'd
/// C string (caller frees with `tado_string_free`) or null if there's
/// been no title since the last drain.
#[no_mangle]
pub unsafe extern "C" fn tado_session_take_title(session: *mut TadoSession) -> *mut c_char {
    if session.is_null() {
        return ptr::null_mut();
    }
    let r = panic::catch_unwind(|| -> *mut c_char {
        let s = &*(session as *const Session);
        match s.take_title() {
            Some(t) => {
                let sanitized: Vec<u8> =
                    t.into_bytes().into_iter().filter(|b| *b != 0).collect();
                match std::ffi::CString::new(sanitized) {
                    Ok(c) => c.into_raw(),
                    Err(_) => ptr::null_mut(),
                }
            }
            None => ptr::null_mut(),
        }
    });
    r.unwrap_or(ptr::null_mut())
}

/// Pull + clear the pending bell count. Returns 0 when no bells have
/// arrived since the last call. Swift's draw loop reads this each
/// idle-tick and rings NSBeep when non-zero.
#[no_mangle]
pub unsafe extern "C" fn tado_session_take_bell_count(session: *mut TadoSession) -> u32 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.take_bell_count()
    });
    r.unwrap_or(0)
}

/// Free a string returned by `tado_session_take_title` (or any other
/// Rust-side CString). No-op on null.
#[no_mangle]
pub unsafe extern "C" fn tado_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        drop(std::ffi::CString::from_raw(s));
    });
}

/// Snapshot just the dirty rows since the last snapshot call.
#[no_mangle]
pub unsafe extern "C" fn tado_session_snapshot_dirty(
    session: *mut TadoSession,
) -> *mut TadoSnapshot {
    if session.is_null() {
        return ptr::null_mut();
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        let snap = s.snapshot_dirty();
        Box::into_raw(Box::new(snap)) as *mut TadoSnapshot
    });
    r.unwrap_or(ptr::null_mut())
}

/// Snapshot the entire grid (use for initial upload / resize).
#[no_mangle]
pub unsafe extern "C" fn tado_session_snapshot_full(
    session: *mut TadoSession,
) -> *mut TadoSnapshot {
    if session.is_null() {
        return ptr::null_mut();
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        let snap = s.snapshot_full();
        Box::into_raw(Box::new(snap)) as *mut TadoSnapshot
    });
    r.unwrap_or(ptr::null_mut())
}

/// Capture the current live grid into the session's viewport history
/// ring buffer. Intended to be called at ~2 fps from the Swift render
/// loop; see `Session::capture_viewport_frame`.
#[no_mangle]
pub unsafe extern "C" fn tado_session_capture_viewport_frame(session: *mut TadoSession) {
    if session.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.capture_viewport_frame();
    });
}

/// Number of frames currently buffered in viewport history.
#[no_mangle]
pub unsafe extern "C" fn tado_session_viewport_frame_count(session: *mut TadoSession) -> u32 {
    if session.is_null() {
        return 0;
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        s.viewport_frame_count()
    });
    r.unwrap_or(0)
}

/// Snapshot a single historical frame, `offset` frames back from the
/// newest (offset 1 = previous frame). Returns null past the end of
/// history or when offset == 0. Caller must free with
/// `tado_snapshot_free` when done.
#[no_mangle]
pub unsafe extern "C" fn tado_session_viewport_frame_snapshot(
    session: *mut TadoSession,
    offset: u32,
) -> *mut TadoSnapshot {
    if session.is_null() {
        return ptr::null_mut();
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        match s.viewport_frame_snapshot(offset) {
            Some(snap) => Box::into_raw(Box::new(snap)) as *mut TadoSnapshot,
            None => ptr::null_mut(),
        }
    });
    r.unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cols(snap: *mut TadoSnapshot) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).cols
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_rows(snap: *mut TadoSnapshot) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).rows
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cursor_x(snap: *mut TadoSnapshot) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).cursor_x
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cursor_y(snap: *mut TadoSnapshot) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).cursor_y
}

/// 1 if the cursor should be rendered, 0 if hidden by DECTCEM (CSI ?25l).
#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cursor_visible(snap: *mut TadoSnapshot) -> u8 {
    if snap.is_null() {
        return 1;
    }
    (&*(snap as *const GridSnapshot)).cursor_visible as u8
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_dirty_row_count(snap: *mut TadoSnapshot) -> usize {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).dirty_rows.len()
}

/// Pointer to the dirty row indices (u16). Lives as long as the snapshot.
#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_dirty_rows(snap: *mut TadoSnapshot) -> *const u16 {
    if snap.is_null() {
        return ptr::null();
    }
    (&*(snap as *const GridSnapshot)).dirty_rows.as_ptr()
}

/// Pointer to the packed cell buffer. Length is
/// `dirty_row_count * cols`. Lives as long as the snapshot.
#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cells(snap: *mut TadoSnapshot) -> *const TadoCell {
    if snap.is_null() {
        return ptr::null();
    }
    let s = &*(snap as *const GridSnapshot);
    s.cells.as_ptr() as *const TadoCell
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_cells_len(snap: *mut TadoSnapshot) -> usize {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const GridSnapshot)).cells.len()
}

#[no_mangle]
pub unsafe extern "C" fn tado_snapshot_free(snap: *mut TadoSnapshot) {
    if snap.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        drop(Box::from_raw(snap as *mut GridSnapshot));
    });
}

// ---------------------------------------------------------------------------
// Scrollback FFI
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct TadoScrollback {
    _priv: [u8; 0],
}

/// Snapshot `rows` lines of scrollback starting `offset` lines back from the
/// most-recently-evicted line. Oldest line first inside the returned cell
/// buffer. Caller must free with `tado_scrollback_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_session_scrollback(
    session: *mut TadoSession,
    offset: usize,
    rows: usize,
) -> *mut TadoScrollback {
    if session.is_null() {
        return ptr::null_mut();
    }
    let r = panic::catch_unwind(|| {
        let s = &*(session as *const Session);
        let snap = s.scrollback_snapshot(offset, rows);
        Box::into_raw(Box::new(snap)) as *mut TadoScrollback
    });
    r.unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_cols(snap: *mut TadoScrollback) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const ScrollbackSnapshot)).cols
}

#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_rows(snap: *mut TadoScrollback) -> u16 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const ScrollbackSnapshot)).rows
}

#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_cells(snap: *mut TadoScrollback) -> *const TadoCell {
    if snap.is_null() {
        return ptr::null();
    }
    let s = &*(snap as *const ScrollbackSnapshot);
    s.cells.as_ptr() as *const TadoCell
}

#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_cells_len(snap: *mut TadoScrollback) -> usize {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const ScrollbackSnapshot)).cells.len()
}

/// Total scrollback lines currently buffered (independent of the most recent
/// snapshot window). Useful for scrollbar sizing.
#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_total_available(snap: *mut TadoScrollback) -> u32 {
    if snap.is_null() {
        return 0;
    }
    (&*(snap as *const ScrollbackSnapshot)).total_available
}

#[no_mangle]
pub unsafe extern "C" fn tado_scrollback_free(snap: *mut TadoScrollback) {
    if snap.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        drop(Box::from_raw(snap as *mut ScrollbackSnapshot));
    });
}

// Sanity: Cell and TadoCell must have identical layout.
const _: () = {
    assert!(std::mem::size_of::<Cell>() == std::mem::size_of::<TadoCell>());
    assert!(std::mem::align_of::<Cell>() == std::mem::align_of::<TadoCell>());
};

unsafe fn cstr_to_owned(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(|s| s.to_owned())
}
