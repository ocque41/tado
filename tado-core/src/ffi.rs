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

use crate::grid::Cell;
use crate::session::{GridSnapshot, ScrollbackSnapshot, Session};
use std::ffi::{c_char, CStr};
use std::panic;
use std::ptr;
use std::sync::Arc;

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
    let result = panic::catch_unwind(|| {
        let cmd = match cstr_to_owned(cmd) {
            Some(s) => s,
            None => return ptr::null_mut(),
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
            Err(_) => ptr::null_mut(),
        }
    });
    result.unwrap_or(ptr::null_mut())
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
