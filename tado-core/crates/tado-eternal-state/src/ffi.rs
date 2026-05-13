//! C-ABI wrapper around `read_run_snapshot`.
//!
//! Exposed to Swift through `tado-terminal`'s re-export. The Swift
//! `EternalRunStateCache` calls this once per `ingest`, decodes
//! the returned JSON string with `JSONDecoder` into its
//! `Snapshot` type, then frees the buffer through
//! `tado_eternal_state_string_free`.
//!
//! The shim returns a heap-allocated, NUL-terminated UTF-8 buffer.
//! Ownership transfers to the caller — Swift must call
//! `tado_eternal_state_string_free` exactly once per non-null
//! return. Returning a `*mut c_char` (rather than filling a caller
//! buffer) keeps the shim simple and matches the existing
//! `tado-terminal` FFI conventions for variable-length payloads
//! (see `tado_dome_status_line_install_path`).

use crate::read_run_snapshot;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

/// Read one run dir's snapshot and return it as a JSON string.
///
/// # Safety
///
/// `run_dir_cstr` must be a NUL-terminated UTF-8 string pointing to
/// a directory path. Returns null on any failure (invalid pointer,
/// non-UTF-8 path, JSON encode failure). On success, the returned
/// pointer must be freed with `tado_eternal_state_string_free`.
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
    let snap = read_run_snapshot(Path::new(path_str));
    let Ok(json) = serde_json::to_string(&snap) else {
        return std::ptr::null_mut();
    };
    let Ok(cstring) = CString::new(json) else {
        return std::ptr::null_mut();
    };
    cstring.into_raw()
}

/// Free a buffer returned by `tado_eternal_state_snapshot`.
///
/// # Safety
///
/// `ptr` must be either null (no-op) or a pointer previously
/// returned by `tado_eternal_state_snapshot`. Calling on any other
/// pointer is undefined behavior.
#[no_mangle]
pub unsafe extern "C" fn tado_eternal_state_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    drop(CString::from_raw(ptr));
}
