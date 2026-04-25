//! C-ABI re-exports of sibling workspace crates.
//!
//! `Package.swift` links a single static library (`libtado_core.a`).
//! For Swift to reach symbols from `tado-ipc` and `tado-settings`,
//! they need to be `#[no_mangle] extern "C"` somewhere inside *this*
//! crate so the linker bakes them into the unified `.a`. The shims
//! here forward to the sibling crate's safe Rust API and translate
//! types at the boundary (C strings ↔ Rust strings, status codes ↔
//! Result types).
//!
//! Memory ownership convention used by every shim returning a string:
//! the returned `*mut c_char` is heap-allocated by Rust via
//! `CString::into_raw`. The Swift caller MUST hand it back to
//! [`tado_string_free`] when done; otherwise it leaks. We can't use
//! Swift's free because the allocator is different.
//!
//! Status codes returned by mutating shims:
//! - `0`  — success
//! - `1`  — `Tado isn't running` (path missing)
//! - `2`  — invalid input (UTF-8 / JSON parse failure)
//! - `3`  — IO error
//! - `255` — unknown error

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use uuid::Uuid;

// ── Shared string helper ─────────────────────────────────────────
//
// Strings returned by these shims are heap-allocated via Rust's
// `CString::into_raw`. Swift hands each one back to the existing
// `tado_string_free` (defined in `ffi.rs` for the terminal shims —
// shared symbol because all of these allocate via the same Rust
// allocator). Don't re-define it here; the linker would reject a
// duplicate symbol.

unsafe fn cstr_to_str<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s).to_str().ok()
}

fn string_to_c(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// ── tado-ipc shims ───────────────────────────────────────────────

/// Drop a message envelope into Tado's external IPC inbox. Used by
/// non-Swift callers that want to reach a running Tado instance via
/// the same contract Dome's Copy-to-Tado extension uses.
///
/// `target_uuid_cstr` is the destination session id as a UTF-8
/// hyphenated UUID string. `body_cstr` is the message body (UTF-8).
/// `from_name_cstr` is the human-readable sender label.
///
/// # Safety
/// All `*const c_char` arguments must point to NUL-terminated UTF-8
/// strings.
#[no_mangle]
pub unsafe extern "C" fn tado_ipc_send_external_message(
    target_uuid_cstr: *const c_char,
    body_cstr: *const c_char,
    from_name_cstr: *const c_char,
) -> c_int {
    let Some(target_str) = cstr_to_str(target_uuid_cstr) else { return 2; };
    let Some(body) = cstr_to_str(body_cstr) else { return 2; };
    let from_name = cstr_to_str(from_name_cstr).unwrap_or("tado-core FFI");

    let target = match Uuid::parse_str(target_str) {
        Ok(u) => u,
        Err(_) => return 2,
    };

    let paths = tado_ipc::IpcPaths::stable();
    let msg = tado_ipc::IpcMessage::new(
        tado_ipc::IpcMessage::external_origin_uuid(),
        from_name.to_string(),
        target,
        body.to_string(),
    );
    match tado_ipc::write_external_message(&paths, &msg) {
        Ok(_) => 0,
        Err(tado_ipc::OutboundError::InboxMissing { .. }) => 1,
        Err(tado_ipc::OutboundError::Serialize(_)) => 2,
        Err(tado_ipc::OutboundError::Io(_)) => 3,
    }
}

/// Read Tado's session registry (`/tmp/tado-ipc/registry.json`) and
/// return the JSON contents as a heap-allocated C string. Returns
/// `null` if the file is missing or unreadable.
///
/// Caller frees with [`tado_string_free`].
#[no_mangle]
pub unsafe extern "C" fn tado_ipc_read_registry_json() -> *mut c_char {
    let paths = tado_ipc::IpcPaths::stable();
    let path = paths.registry_json();
    match std::fs::read_to_string(&path) {
        Ok(s) => string_to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// A1 slice 1 — Write Tado's session registry through Rust.
///
/// Takes a pre-serialized JSON array of `IpcSessionEntry` (the
/// exact shape Swift's `IPCBroker.updateRegistry` already produces),
/// parses + validates it in Rust, and re-emits it through
/// `tado_ipc::write_registry`, which enforces the Swift-pretty byte
/// layout + atomic replace (tmp + rename).
///
/// Going through Rust lets external consumers (future CLI in Rust,
/// Dome's Copy-to-Tado extension) reuse the same serializer Swift
/// writes with, which matters the day Swift migrates off
/// `JSONEncoder.prettyPrinted` and we need a single place to track
/// the format. Returns 0 on success, 2 on JSON parse failure, 3 on
/// IO error, 255 on any other path.
///
/// `root_cstr` may be null to mean `/tmp/tado-ipc` (stable symlink);
/// otherwise it's the IPC root (e.g. `/tmp/tado-ipc-<pid>`).
///
/// # Safety
/// `json_cstr` must be a NUL-terminated UTF-8 string. `root_cstr`
/// must be null or a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tado_ipc_write_registry_json(
    root_cstr: *const c_char,
    json_cstr: *const c_char,
) -> c_int {
    let Some(json) = cstr_to_str(json_cstr) else { return 2; };
    let entries: Vec<tado_ipc::IpcSessionEntry> = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return 2,
    };
    let paths = if root_cstr.is_null() {
        tado_ipc::IpcPaths::stable()
    } else {
        let Some(s) = cstr_to_str(root_cstr) else { return 2; };
        tado_ipc::IpcPaths::at(s)
    };
    match tado_ipc::write_registry(&paths, &entries) {
        Ok(()) => 0,
        Err(tado_ipc::RegistryError::Io(_)) => 3,
        Err(tado_ipc::RegistryError::Json(_)) => 2,
    }
}

/// Start the real-time A2A event socket (A6). Binds a Unix-domain
/// socket at `socket_path_cstr` and keeps it serving for the rest of
/// the process lifetime. Idempotent — a second call is a silent
/// no-op that still returns 0.
///
/// If `socket_path_cstr` is null, defaults to the stable IPC root's
/// `events.sock` (i.e. `/tmp/tado-ipc/events.sock`). Swift normally
/// passes `/tmp/tado-ipc-<pid>/events.sock` so the per-PID directory
/// created by `IPCBroker` owns the file.
///
/// Returns 0 on success, 2 on invalid UTF-8 in the path, 3 on IO
/// error (dir creation or bind).
///
/// # Safety
/// `socket_path_cstr` must be null or point to a NUL-terminated UTF-8
/// string naming a writable location whose parent directory either
/// exists or can be created.
#[no_mangle]
pub unsafe extern "C" fn tado_events_start(socket_path_cstr: *const c_char) -> c_int {
    let path = if socket_path_cstr.is_null() {
        tado_ipc::IpcPaths::stable().events_sock()
    } else {
        let Some(s) = cstr_to_str(socket_path_cstr) else { return 2; };
        std::path::PathBuf::from(s)
    };
    match tado_ipc::start_events_server(&path) {
        Ok(()) => 0,
        Err(tado_ipc::EventsError::Io(_)) => 3,
        Err(tado_ipc::EventsError::Runtime(_)) => 255,
    }
}

/// Publish an event onto the real-time socket started by
/// [`tado_events_start`]. Silently dropped if the server hasn't been
/// started yet; callers don't need to check — the Swift `EventBus`
/// deliverer is registered after the start call at app launch.
///
/// `kind_cstr` is the event kind (`terminal.spawned`, `topic:planning`,
/// `spawn.requested`, etc.). `payload_json_cstr` is a JSON object
/// string carrying the event's data; invalid JSON is replaced with
/// an empty object so a malformed publish can't crash the bridge.
///
/// Returns 0 on success, 2 on invalid UTF-8 in either argument.
///
/// # Safety
/// Both pointers must be NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn tado_events_publish(
    kind_cstr: *const c_char,
    payload_json_cstr: *const c_char,
) -> c_int {
    let Some(kind) = cstr_to_str(kind_cstr) else { return 2; };
    let payload_str = cstr_to_str(payload_json_cstr).unwrap_or("{}");
    let payload: serde_json::Value =
        serde_json::from_str(payload_str).unwrap_or_else(|_| serde_json::json!({}));
    tado_ipc::publish_event(kind, payload);
    0
}

// ── tado-settings shims ──────────────────────────────────────────

/// Atomic-write a JSON-encoded payload to `path_cstr`. The payload
/// is parsed via `serde_json` and pretty-printed via tado-settings's
/// `write_json` (temp + sync + rename).
///
/// Returns 0 on success, 2 on JSON parse failure, 3 on IO error.
///
/// # Safety
/// Both pointers must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn tado_settings_write_json(
    path_cstr: *const c_char,
    json_cstr: *const c_char,
) -> c_int {
    let Some(path) = cstr_to_str(path_cstr) else { return 2; };
    let Some(json) = cstr_to_str(json_cstr) else { return 2; };
    let value: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return 2,
    };
    match tado_settings::write_json(path, &value) {
        Ok(_) => 0,
        Err(tado_settings::AtomicError::Serialize(_)) => 2,
        Err(_) => 3,
    }
}

/// Read a JSON file into a heap-allocated C string. Returns null
/// on missing file (caller treats as scope-empty). Caller frees
/// with [`tado_string_free`].
///
/// # Safety
/// `path_cstr` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tado_settings_read_json(path_cstr: *const c_char) -> *mut c_char {
    let Some(path) = cstr_to_str(path_cstr) else { return std::ptr::null_mut(); };
    let value: Option<serde_json::Value> = match tado_settings::read_json(path) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    match value {
        Some(v) => match serde_json::to_string(&v) {
            Ok(s) => string_to_c(s),
            Err(_) => std::ptr::null_mut(),
        },
        None => std::ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::tado_string_free;

    #[test]
    fn settings_roundtrip_through_ffi() {
        let dir = std::env::temp_dir().join(format!(
            "tado-ffi-test-{}",
            uuid::Uuid::new_v4().as_hyphenated()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        let path_c = CString::new(path.to_string_lossy().as_bytes()).unwrap();
        let json_c = CString::new(r#"{"name":"alice","count":42}"#).unwrap();

        unsafe {
            assert_eq!(tado_settings_write_json(path_c.as_ptr(), json_c.as_ptr()), 0);
            let read_back = tado_settings_read_json(path_c.as_ptr());
            assert!(!read_back.is_null());
            let s = CStr::from_ptr(read_back).to_str().unwrap().to_string();
            tado_string_free(read_back);
            assert!(s.contains(r#""name":"alice""#));
            assert!(s.contains(r#""count":42"#));
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_missing_file_returns_null() {
        let path_c = CString::new("/nonexistent/path/to/file.json").unwrap();
        unsafe {
            let result = tado_settings_read_json(path_c.as_ptr());
            assert!(result.is_null());
        }
    }

    #[test]
    fn invalid_uuid_in_send_returns_2() {
        let target_c = CString::new("not-a-uuid").unwrap();
        let body_c = CString::new("hello").unwrap();
        let from_c = CString::new("test").unwrap();
        unsafe {
            assert_eq!(
                tado_ipc_send_external_message(target_c.as_ptr(), body_c.as_ptr(), from_c.as_ptr()),
                2
            );
        }
    }

    #[test]
    fn read_registry_when_missing_returns_null() {
        // Don't expect /tmp/tado-ipc to exist in the test sandbox.
        unsafe {
            // Either null (file missing) or a real string — either way,
            // the call must not panic. Don't assert null because the
            // test machine might actually have Tado running.
            let result = tado_ipc_read_registry_json();
            if !result.is_null() {
                tado_string_free(result);
            }
        }
    }
}
