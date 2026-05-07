//! Re-export shim for `tado-eternal-state`'s FFI surface.
//!
//! `tado-terminal`'s staticlib is the only `.a` Package.swift links,
//! so every C-ABI entry the Swift app calls must be defined HERE
//! (or in another `tado-terminal` module). The actual
//! `read_run_snapshot` lives in the `tado-eternal-state` crate; this
//! module wraps it in a `#[no_mangle] pub unsafe extern "C"` shim
//! so the symbol `tado_eternal_state_snapshot` lands directly in the
//! unified `libtado_core.a` Package.swift links.
//!
//! Free convention: returned strings use the global `tado_string_free`
//! helper at `ffi.rs:396` — same convention as `tado_dome_*`,
//! `tado_ipc_*`, `tado_settings_*`. Keeps the Swift side from having
//! to remember per-family free helpers.
//!
//! See `dome_ffi.rs` / `sibling_ffi.rs` for the same discipline
//! applied to bt-core / dome-eval / tado-ipc / tado-settings.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

/// Read one Eternal run dir's snapshot and return it as a JSON
/// string for the Swift `EternalRunStateCache` to decode. See
/// `tado_eternal_state::EternalRunStateSnapshot` for the wire shape.
///
/// Ownership: caller frees via `tado_string_free`.
///
/// # Safety
///
/// `run_dir_cstr` must be a NUL-terminated UTF-8 string pointing to
/// a directory path the process is allowed to read. Returns null on
/// any failure (invalid pointer, non-UTF-8 path, JSON encode error).
#[no_mangle]
pub unsafe extern "C" fn tado_eternal_state_snapshot(
    run_dir_cstr: *const c_char,
) -> *mut c_char {
    if run_dir_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let cstr = CStr::from_ptr(run_dir_cstr);
    let Ok(path_str) = cstr.to_str() else {
        return std::ptr::null_mut();
    };
    let snap = tado_eternal_state::read_run_snapshot(Path::new(path_str));
    let Ok(json) = serde_json::to_string(&snap) else {
        return std::ptr::null_mut();
    };
    let Ok(cstring) = CString::new(json) else {
        return std::ptr::null_mut();
    };
    cstring.into_raw()
}
