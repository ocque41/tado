//! C-ABI entry points for Dome's second-brain daemon.
//!
//! Dome runs in-process inside the Tado app: one binary, one Activity
//! Monitor row. Swift's `DomeExtension.onAppLaunch()` calls
//! [`tado_dome_start`] once at app launch; bt-core's RPC loop then
//! runs on a dedicated Tokio runtime owned by this module for the
//! remainder of the process lifetime.
//!
//! Why this lives inside tado-terminal rather than bt-core
//! -------------------------------------------------------
//! Only symbols inside the crate that produces `libtado_core.a`
//! (`tado-terminal`, per `[lib] crate-type = ["staticlib"]`) ship
//! into the archive Swift links against. Declaring the `#[no_mangle]
//! extern "C"` wrappers here is what guarantees the linker finds
//! them from Swift. See `sibling_ffi.rs` for the same pattern applied
//! to tado-ipc + tado-settings.
//!
//! Ownership + threading
//! ---------------------
//! A single `Runtime` is lazily created on first `tado_dome_start` and
//! retained in a `OnceLock` for the process lifetime. The `CoreService`
//! is cloned into a second `OnceLock` (`DOME_SERVICE`) so follow-up
//! FFI calls — `tado_dome_issue_token`, context-preamble composition
//! (future), etc. — can reach the same live vault without re-opening
//! it. `CoreService` is Arc-internal, so cloning is cheap.
//!
//! Status codes (where applicable)
//! -------------------------------
//! - `0`   — success (daemon already running or just started)
//! - `2`   — invalid vault path (UTF-8 or validation failure)
//! - `3`   — IO / runtime boot error
//! - `255` — unknown error
//!
//! String-returning shims return a heap-allocated `*mut c_char` on
//! success (caller frees via `tado_string_free`) or a null pointer on
//! failure.

use bt_core::{Actor, CoreService};
use serde_json::json;
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

/// Process-wide Tokio runtime hosting bt-core's RPC loop + scheduler
/// tick. Initialized on first `tado_dome_start`; never reset.
static DOME_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Clone of the `CoreService` we handed to `run_daemon`. Retained so
/// follow-up FFI calls (token issuance, preamble composition, etc.)
/// can reach the same vault without re-opening it. `CoreService`
/// derives `Clone` — it's Arc-internal, so the clone is cheap and
/// shares the live SQLite handle + vault-root cache with the daemon
/// task.
static DOME_SERVICE: OnceLock<CoreService> = OnceLock::new();

/// Flag guarding double-start. Once the daemon is live, subsequent
/// `tado_dome_start` calls return 0 immediately without reopening the
/// vault or rebinding the socket.
static DOME_STARTED: OnceLock<()> = OnceLock::new();

/// Boot Dome's in-process daemon against the given vault path.
///
/// Creates a dedicated multi-threaded Tokio runtime (2 worker threads,
/// enough for the scheduler tick + per-connection handler pattern
/// Dome uses) and spawns `bt_core::rpc::run_daemon` on it. The
/// daemon binds a Unix socket inside the vault at
/// `<vault>/.bt/bt-core.sock` that `dome-mcp` and the Swift Dome
/// surfaces connect to.
///
/// Idempotent: a second call with any vault path is a no-op and
/// returns 0. (Dome only supports one vault per app lifetime; vault
/// switching isn't planned for v0.)
///
/// # Safety
/// `vault_cstr` must point to a NUL-terminated UTF-8 string naming a
/// writable directory (or one we can create).
#[no_mangle]
pub unsafe extern "C" fn tado_dome_start(vault_cstr: *const c_char) -> c_int {
    if DOME_STARTED.get().is_some() {
        return 0;
    }

    if vault_cstr.is_null() {
        return 2;
    }
    let Ok(vault_str) = CStr::from_ptr(vault_cstr).to_str() else {
        return 2;
    };
    let vault_path = Path::new(vault_str).to_path_buf();

    let runtime = match Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("dome-rt")
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return 3,
    };

    let service = CoreService::new();
    if service.open_vault(&vault_path).is_err() {
        return 3;
    }

    // Clone before moving into the spawned task so subsequent FFI
    // calls (token issuance, preamble composition) can reuse the
    // same live vault.
    let daemon_service = service.clone();
    runtime.spawn(async move {
        if let Err(err) = bt_core::rpc::run_daemon(daemon_service).await {
            eprintln!("[dome] run_daemon exited: {}", err);
        }
    });

    // Retain the runtime + service for the process lifetime. If the
    // OnceLock set fails we're already initialized — return 0 anyway.
    let _ = DOME_RUNTIME.set(runtime);
    let _ = DOME_SERVICE.set(service);
    let _ = DOME_STARTED.set(());
    0
}

/// Shut down the Dome daemon.
///
/// Phase-2 stub: the OS reclaims the runtime on app exit and the
/// socket file is removed on next start (bt-core unlinks before
/// bind). A real graceful-shutdown implementation would signal the
/// RPC loop to stop accepting + drain in-flight handlers, but that's
/// not needed for Phase-2 verification.
#[no_mangle]
pub extern "C" fn tado_dome_stop() -> c_int {
    0
}

/// Issue a fresh Dome agent token for an MCP caller.
///
/// Wraps `CoreService::token_create(agent_name, caps)` — mints a
/// token, persists it to `<vault>/.bt/config.toml`, and returns the
/// raw token value as a heap-allocated C string for the caller to
/// pass verbatim to `claude mcp add`. Caller frees with
/// `tado_string_free`.
///
/// `caps_csv` is a comma-separated list of capability names
/// (e.g. `"search,read,note,schedule"` for the default dome-mcp
/// surface). Whitespace is trimmed per entry; empty entries are
/// skipped. A null pointer is treated as "no caps" which bt-core
/// interprets as full agent scope.
///
/// Returns null on any failure (FFI convention matches the other
/// Dome shims). Failure reasons:
/// - Vault not open (caller didn't run `tado_dome_start` first, or
///   it failed to open)
/// - agent_name not valid UTF-8 or null
/// - bt-core rejected the token (e.g. vault write failure)
///
/// # Safety
/// `agent_name_cstr` must point to a NUL-terminated UTF-8 string.
/// `caps_csv_cstr` must be either null or a NUL-terminated UTF-8
/// string.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_issue_token(
    agent_name_cstr: *const c_char,
    caps_csv_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    if agent_name_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(agent_name) = CStr::from_ptr(agent_name_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let caps: Vec<String> = if caps_csv_cstr.is_null() {
        Vec::new()
    } else {
        let Ok(csv) = CStr::from_ptr(caps_csv_cstr).to_str() else {
            return std::ptr::null_mut();
        };
        csv.split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect()
    };

    let result = match service.token_create(agent_name, caps) {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    // token_create returns { "token": "<raw>", ... }. Extract the raw
    // string; anything else is a bt-core contract break.
    let Some(raw) = result.get("token").and_then(|v| v.as_str()) else {
        return std::ptr::null_mut();
    };

    CString::new(raw)
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// ── H3: Dome note CRUD for Swift surfaces ─────────────────────────
//
// These shims back the four Dome surfaces (User Notes, Agent Notes,
// Calendar, Knowledge). They call into the same `CoreService` the
// daemon exposes via Unix-socket RPC, but through direct in-process
// method calls — no socket round-trip per UI interaction.
//
// Ownership: every string-returning function hands out a heap-
// allocated `*mut c_char`; Swift frees via `tado_string_free` (same
// allocator boundary as the other shims).

/// Actor identity used by the Swift UI when writing. bt-core's write
/// barrier distinguishes "user-authored" from "agent-authored" by the
/// Actor variant; the UI is always a user actor. The session_id field
/// is a stable label — we pass "tado-ui" so every audit entry from
/// the Dome window is identifiable.
fn swift_ui_actor() -> Actor {
    Actor::UserUi {
        session_id: "tado-ui".to_string(),
    }
}

fn to_cstr(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// Create a new Dome note and write its body.
///
/// Params:
/// - `scope_cstr`: `"user"` writes to `user.md`; `"agent"` writes to
///   `agent.md`. Anything else → null return.
/// - `topic_cstr`: slug-safe topic (e.g. `"user"` for the User Notes
///   tab, `"project:abc123"` for project-scoped notes). bt-core
///   sanitizes; spaces → dashes.
/// - `title_cstr`: human-readable title. Doubles as the slug if no
///   explicit slug is passed (none is).
/// - `body_cstr`: markdown body to write (replace mode, so previous
///   content if any is overwritten).
///
/// Returns a heap-allocated JSON string `{"id": "<uuid>"}` on success
/// or null on any failure. Caller frees with `tado_string_free`.
///
/// # Safety
/// All pointers must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_write(
    scope_cstr: *const c_char,
    topic_cstr: *const c_char,
    title_cstr: *const c_char,
    body_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    if scope_cstr.is_null() || topic_cstr.is_null() || title_cstr.is_null() || body_cstr.is_null() {
        return std::ptr::null_mut();
    }

    let Ok(scope) = CStr::from_ptr(scope_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(topic) = CStr::from_ptr(topic_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(title) = CStr::from_ptr(title_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(body) = CStr::from_ptr(body_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let actor = swift_ui_actor();

    // Create the doc shell. doc_create sets up user.md + agent.md
    // with starter headings; we then overwrite whichever side matches
    // the requested scope.
    let created = match service.doc_create(&actor, topic, title, None) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let Some(id) = created.get("id").and_then(|v| v.as_str()) else {
        return std::ptr::null_mut();
    };
    let id_string = id.to_string();

    let update_result = match scope {
        "user" => service.doc_update_user(&actor, &id_string, body, "replace"),
        "agent" => service.doc_update_agent(&actor, &id_string, body, "replace", false),
        _ => return std::ptr::null_mut(),
    };

    if update_result.is_err() {
        return std::ptr::null_mut();
    }

    to_cstr(json!({ "id": id_string }).to_string())
}

/// Create a scoped Dome knowledge note and write its body.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_write_scoped(
    note_scope_cstr: *const c_char,
    topic_cstr: *const c_char,
    title_cstr: *const c_char,
    body_cstr: *const c_char,
    owner_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
    project_root_cstr: *const c_char,
    knowledge_kind_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if note_scope_cstr.is_null()
        || topic_cstr.is_null()
        || title_cstr.is_null()
        || body_cstr.is_null()
    {
        return std::ptr::null_mut();
    }
    let Ok(note_scope) = CStr::from_ptr(note_scope_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(topic) = CStr::from_ptr(topic_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(title) = CStr::from_ptr(title_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(body) = CStr::from_ptr(body_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let owner_scope = optional_cstr(owner_scope_cstr).unwrap_or("global");
    let project_id = optional_cstr(project_id_cstr);
    let project_root = optional_cstr(project_root_cstr);
    let knowledge_kind = optional_cstr(knowledge_kind_cstr).unwrap_or("knowledge");
    let actor = swift_ui_actor();

    let result = service.knowledge_register(
        &actor,
        title,
        body,
        owner_scope,
        project_id,
        project_root,
        Some(topic),
        Some(knowledge_kind),
        Some(note_scope),
    );

    match result {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Replace the user side of an existing note.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_update_user(
    id_cstr: *const c_char,
    body_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() || body_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(body) = CStr::from_ptr(body_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    match service.doc_update_user(&swift_ui_actor(), id, body, "replace") {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Update only the display title of an existing note.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_rename_title(
    id_cstr: *const c_char,
    title_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() || title_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(title) = CStr::from_ptr(title_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    match service.doc_rename(&swift_ui_actor(), id, Some(title), None, None) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List notes filtered by topic (or all if topic is null/empty).
///
/// Params:
/// - `topic_cstr`: topic slug to filter by, or null to list every
///   note in the vault. Empty string is treated as null.
/// - `_limit`: currently ignored — doc_list always returns every
///   matching doc. The parameter is kept in the ABI for forward-
///   compatibility; Swift-side slicing enforces pagination today.
///
/// Returns the `docs` array from `doc_list` as a JSON string. Each
/// entry includes `id`, `title`, `topic`, `created_at`, `updated_at`,
/// `agent_active`, and paths. Caller frees with `tado_string_free`.
///
/// # Safety
/// `topic_cstr` may be null. If non-null, must be NUL-terminated
/// UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_notes_list(
    topic_cstr: *const c_char,
    _limit: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    let topic: Option<&str> = if topic_cstr.is_null() {
        None
    } else {
        match CStr::from_ptr(topic_cstr).to_str() {
            Ok(s) if s.is_empty() => None,
            Ok(s) => Some(s),
            Err(_) => return std::ptr::null_mut(),
        }
    };

    let result = match service.doc_list(topic, false) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    to_cstr(result.to_string())
}

/// List notes through Dome's scoped knowledge filter.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_notes_list_scoped(
    topic_cstr: *const c_char,
    _limit: c_int,
    knowledge_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
    include_global: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    let topic: Option<&str> = if topic_cstr.is_null() {
        None
    } else {
        match CStr::from_ptr(topic_cstr).to_str() {
            Ok(s) if s.is_empty() => None,
            Ok(s) => Some(s),
            Err(_) => return std::ptr::null_mut(),
        }
    };
    let knowledge_scope = optional_cstr(knowledge_scope_cstr);
    let project_id = optional_cstr(project_id_cstr);

    let result = match service.doc_list_scoped(
        topic,
        false,
        knowledge_scope,
        project_id,
        Some(include_global),
    ) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    to_cstr(result.to_string())
}

/// Create a topic directory explicitly.
///
/// Returns `{"topic":"<slug>","created":true}` on success.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_topic_create(topic_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if topic_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(topic) = CStr::from_ptr(topic_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let result = match service.topic_create(&swift_ui_actor(), topic) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    to_cstr(result.to_string())
}

/// Hard-delete a note document.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_delete(id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let result = match service.doc_delete(&swift_ui_actor(), id) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    to_cstr(result.to_string())
}

/// Fetch a single note with both user + agent content inlined.
///
/// Params:
/// - `id_cstr`: note uuid (from `tado_dome_notes_list`).
///
/// Returns the `doc_get` payload as a JSON string — `id`, `title`,
/// `topic`, `user_content`, `agent_content`, `updated_at`, etc.
/// Caller frees with `tado_string_free`.
///
/// # Safety
/// `id_cstr` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_note_get(id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    let result = match service.doc_get(Some(id), None, true, true, true) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    to_cstr(result.to_string())
}

/// Return a graph snapshot for the Knowledge → Graph surface.
///
/// All pointer arguments are optional except `include_types_json_cstr`,
/// which may also be null. `include_types_json_cstr` must be a JSON
/// array of node kind strings when present.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_graph_snapshot(
    focus_node_id_cstr: *const c_char,
    include_types_json_cstr: *const c_char,
    search_cstr: *const c_char,
    max_nodes: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    let focus_node_id = optional_cstr(focus_node_id_cstr);
    let search = optional_cstr(search_cstr);
    let include_types = optional_cstr(include_types_json_cstr)
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok());
    let max_nodes = if max_nodes > 0 {
        Some(max_nodes as usize)
    } else {
        None
    };

    match service.graph_snapshot(
        focus_node_id,
        include_types.as_ref(),
        None,
        None,
        search,
        max_nodes,
        None,
        None,
        None,
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Return a scoped graph snapshot for the Knowledge → Graph surface.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_graph_snapshot_scoped(
    focus_node_id_cstr: *const c_char,
    include_types_json_cstr: *const c_char,
    search_cstr: *const c_char,
    max_nodes: c_int,
    knowledge_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
    include_global: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };

    let focus_node_id = optional_cstr(focus_node_id_cstr);
    let search = optional_cstr(search_cstr);
    let include_types = optional_cstr(include_types_json_cstr)
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok());
    let max_nodes = if max_nodes > 0 {
        Some(max_nodes as usize)
    } else {
        None
    };

    match service.graph_snapshot(
        focus_node_id,
        include_types.as_ref(),
        None,
        None,
        search,
        max_nodes,
        optional_cstr(knowledge_scope_cstr),
        optional_cstr(project_id_cstr),
        Some(include_global),
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Force-refresh the graph projection.
#[no_mangle]
pub extern "C" fn tado_dome_graph_refresh() -> c_int {
    let Some(service) = DOME_SERVICE.get() else {
        return 2;
    };
    match service.handle_rpc("graph.refresh", json!({})) {
        Ok(_) => 0,
        Err(_) => 255,
    }
}

/// Fetch a graph node inspector payload by node id.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_graph_node_get(node_id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if node_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(node_id) = CStr::from_ptr(node_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };

    match service.graph_node_get(node_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Fetch Claude-agent operational status for Knowledge → System.
#[no_mangle]
pub extern "C" fn tado_dome_agent_status(limit: c_int) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let limit = if limit > 0 { limit as usize } else { 50 };
    match service.agent_status(limit, None, None, None) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Fetch scoped Claude-agent operational status for Knowledge → System.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_agent_status_scoped(
    limit: c_int,
    knowledge_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
    include_global: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let limit = if limit > 0 { limit as usize } else { 50 };
    match service.agent_status(
        limit,
        optional_cstr(knowledge_scope_cstr),
        optional_cstr(project_id_cstr),
        Some(include_global),
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Install the Tado-owned Claude status line script into the Dome vault.
///
/// This does not mutate Claude settings by itself. Swift can decide how
/// aggressively to register the returned script path in user settings.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_install_status_line_script(
    vault_cstr: *const c_char,
) -> *mut c_char {
    if vault_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(vault_str) = CStr::from_ptr(vault_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let vault = Path::new(vault_str);
    let dir = vault.join(".bt/status/claude");
    if fs::create_dir_all(dir.join("latest")).is_err() {
        return std::ptr::null_mut();
    }
    let script_path = dir.join("tado-statusline.py");
    if fs::write(&script_path, STATUS_LINE_SCRIPT).is_err() {
        return std::ptr::null_mut();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = fs::metadata(&script_path) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&script_path, perms);
        }
    }

    to_cstr(
        {
            let script_path_string = script_path.to_string_lossy().to_string();
            let command = shell_escape(&script_path_string);
            json!({
                "script_path": script_path_string,
                "settings": {
                    "statusLine": {
                        "type": "command",
                        "command": command,
                        "padding": 1,
                        "refreshInterval": 5
                    }
                }
            })
        }
        .to_string(),
    )
}

fn shell_escape(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

unsafe fn optional_cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr)
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

const STATUS_LINE_SCRIPT: &str = r#"#!/usr/bin/env python3
import json
import os
import pathlib
import tempfile
from datetime import datetime, timezone

raw = "{}"
try:
    raw = input()
except EOFError:
    pass

try:
    data = json.loads(raw or "{}")
except Exception:
    data = {}

env = os.environ
vault = env.get("TADO_DOME_VAULT")
tado_session = env.get("TADO_SESSION_ID") or data.get("session_id") or "unknown"
agent = env.get("TADO_AGENT_NAME") or (data.get("agent") or {}).get("name") or "claude"
project = env.get("TADO_PROJECT_NAME") or pathlib.Path(data.get("cwd") or "").name or "project"
model = (data.get("model") or {}).get("display_name") or (data.get("model") or {}).get("id") or "model"
ctx = data.get("context_window") or {}
cost = data.get("cost") or {}
pct = ctx.get("used_percentage") or 0
try:
    pct_i = int(float(pct))
except Exception:
    pct_i = 0

capture = {
    "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "tado_session_id": tado_session,
    "claude_session_id": data.get("session_id"),
    "agent_name": agent,
    "project_name": project,
    "project_id": env.get("TADO_PROJECT_ID"),
    "current_dome_pack": env.get("TADO_DOME_CONTEXT_PACK"),
    "retrieval_freshness": env.get("TADO_DOME_RETRIEVAL_FRESHNESS", "unknown"),
    "model_id": (data.get("model") or {}).get("id"),
    "model_display_name": model,
    "context_used_percent": pct,
    "context_window_size": ctx.get("context_window_size"),
    "input_tokens": (ctx.get("current_usage") or {}).get("input_tokens"),
    "output_tokens": (ctx.get("current_usage") or {}).get("output_tokens"),
    "cost_usd": cost.get("total_cost_usd"),
    "transcript_path": data.get("transcript_path"),
    "cwd": data.get("cwd") or (data.get("workspace") or {}).get("current_dir"),
    "raw": data,
}

if vault:
    latest = pathlib.Path(vault) / ".bt" / "status" / "claude" / "latest"
    latest.mkdir(parents=True, exist_ok=True)
    target = latest / f"{tado_session}.json"
    fd, tmp = tempfile.mkstemp(prefix=target.name, suffix=".tmp", dir=str(latest))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(capture, f, ensure_ascii=True, separators=(",", ":"))
            f.write("\n")
        os.replace(tmp, target)
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except Exception:
            pass

cost_s = cost.get("total_cost_usd")
cost_label = f"${float(cost_s):.2f}" if isinstance(cost_s, (int, float)) else "$0.00"
print(f"Tado {agent} | {model} | ctx {pct_i}% | {cost_label} | {project}")
"#;
