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
//!
//! Safety contract (applies to every `unsafe extern "C" fn` in this module)
//! ----------------------------------------------------------------------
//! - Every `*const c_char` parameter must be either null or a pointer to
//!   a NUL-terminated, valid UTF-8 string owned by the caller for the
//!   duration of the call. Each function documents which of its pointer
//!   args are nullable; the rest are required.
//! - Returned `*mut c_char` values are heap-allocated by Rust and must
//!   be freed exactly once via `tado_string_free`.
//! - Calls are safe to make concurrently from any thread; the underlying
//!   `CoreService` is `Sync`-internal.
//!
//! Because every function in this file shares this exact contract, the
//! `clippy::missing_safety_doc` lint is suppressed module-wide — adding
//! a `# Safety` section to each individual function would be 30+ copies
//! of this paragraph.
#![allow(clippy::missing_safety_doc)]

use bt_core::notes::model_fetch::{self, FetchProgress};
use bt_core::notes::qwen3_runtime::Qwen3Runtime;
use bt_core::notes::{embeddings, Qwen3EmbeddingProvider};
use bt_core::{Actor, CoreService};
use serde_json::json;
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::{c_char, c_int};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
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

/// Vault root cached at start so model fetch + load can find the
/// `<vault>/.bt/models/qwen3-embedding-0.6b/` directory after the
/// daemon is running.
static DOME_VAULT: OnceLock<PathBuf> = OnceLock::new();

/// Live progress for the Qwen3 model download. Created on first
/// `tado_dome_model_fetch_start` call. Read via
/// `tado_dome_model_status`.
static MODEL_PROGRESS: OnceLock<Arc<FetchProgress>> = OnceLock::new();

/// Worker-thread guard. `Some(true)` while a fetch is in progress;
/// flipped back to `Some(false)` (or removed) when the thread exits
/// so the user can retry after a transient failure.
static MODEL_FETCH_RUNNING: std::sync::Mutex<bool> = std::sync::Mutex::new(false);

/// Surfaces the most recent runtime-load error to the UI. Cleared
/// when a load succeeds. Read by `tado_dome_model_status` so the
/// onboarding panel can show "model files complete but load failed —
/// here's why" instead of looping silently.
static MODEL_LOAD_ERROR: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

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
    let _ = DOME_VAULT.set(vault_path.clone());
    let _ = DOME_STARTED.set(());

    // Best-effort eager load: if the user already has the complete
    // model files (env override or a prior download), boot the
    // embedding runtime before the first search/index call so
    // retrieval is real-semantic from the very first query.
    if let Some(model_dir) = model_fetch::resolve_model_dir(&vault_path) {
        load_model_into_registry(&model_dir, &vault_path);
    }
    // If the model isn't loaded after the eager pass — files missing
    // entirely, or partial download from a previous run — auto-kick
    // the fetch so the user doesn't have to re-click "Download" each
    // time they reopen the app. The fetch resumes from any partial
    // bytes already on disk.
    if !Qwen3EmbeddingProvider::default().is_runtime_loaded() {
        spawn_model_fetch(&vault_path);
    }

    // Phase 4: reattach file watchers for every previously-enabled
    // project. Survives app restarts so the user doesn't have to
    // re-click "watch" on every launch. Best-effort; failures are
    // logged inside `code_resume_watchers`.
    if let Some(svc) = DOME_SERVICE.get() {
        if let Err(err) = svc.code_resume_watchers() {
            eprintln!("[dome] code_resume_watchers failed: {err}");
        }
    }
    0
}

fn load_model_into_registry(model_dir: &Path, vault: &Path) {
    // BUG FIX: previously this read the dimension via `metadata()`,
    // which returns the noop-fallback (384) when the runtime is not
    // yet attached — i.e., always at this entry point. That truncated
    // every Qwen3 forward pass to 384 dims and stamped it with full
    // Qwen3 metadata, silently corrupting the index. Read the
    // *desired target* dimension directly: env override if set, else
    // the production default (1024).
    let dimension = std::env::var("TADO_DOME_EMBEDDING_DIMENSION")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .map(|d| d.clamp(32, embeddings::DEFAULT_EMBEDDING_DIMENSIONS))
        .unwrap_or(embeddings::DEFAULT_EMBEDDING_DIMENSIONS);
    match Qwen3Runtime::load(model_dir, dimension) {
        Ok(rt) => {
            let runtime_dim = rt.dimension();
            embeddings::install_runtime(Arc::new(Mutex::new(rt)));
            if let Ok(mut g) = MODEL_LOAD_ERROR.lock() {
                *g = None;
            }
            // Sweep stale chunks: if a prior load wrote rows with the
            // wrong dimension under the Qwen3 model_id, those rows
            // are unsearchable (length mismatch crashes cosine) and
            // poison the index. Delete them so the next bootstrap or
            // reindex regenerates them at the correct dimension.
            let cleaned = sweep_corrupt_qwen3_chunks(runtime_dim);
            log_to_fetch(
                vault,
                model_dir,
                &format!(
                    "runtime attached: dim={} dir={} cleaned={}",
                    dimension,
                    model_dir.display(),
                    cleaned
                ),
            );
        }
        Err(err) => {
            let msg = format!("runtime load failed: {err}");
            eprintln!("[dome] {msg}");
            if let Ok(mut g) = MODEL_LOAD_ERROR.lock() {
                *g = Some(msg.clone());
            }
            log_to_fetch(vault, model_dir, &format!("ERROR {msg}"));
        }
    }
}

fn sweep_corrupt_qwen3_chunks(target_dim: usize) -> u64 {
    let Some(svc) = DOME_SERVICE.get() else {
        return 0;
    };
    match svc.purge_corrupt_qwen3_chunks(target_dim) {
        Ok(n) => n,
        Err(err) => {
            eprintln!("[dome] purge_corrupt_qwen3_chunks failed: {err}");
            0
        }
    }
}

fn log_to_fetch(vault: &Path, model_dir: &Path, line: &str) {
    let path = model_fetch::fetch_log_path(vault)
        .unwrap_or_else(|_| model_dir.join("_fetch.log"));
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(
                f,
                "{} {line}",
                chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ")
            )
        });
}

fn spawn_model_fetch(vault_path: &Path) {
    // Don't spawn a second fetch on top of an active one.
    if let Ok(mut running) = MODEL_FETCH_RUNNING.lock() {
        if *running {
            return;
        }
        *running = true;
    } else {
        return;
    }
    // Reset any sticky error from a previous attempt so the UI
    // doesn't show a stale failure message during the new fetch.
    if let Ok(mut g) = MODEL_LOAD_ERROR.lock() {
        *g = None;
    }
    let progress = MODEL_PROGRESS
        .get_or_init(FetchProgress::new)
        .clone();
    // Reset the FetchProgress's sticky error too — disk size is the
    // truth, but the error string is stale across retries.
    progress.record_error_clear();
    let vault = vault_path.to_path_buf();
    let _ = thread::Builder::new()
        .name("dome-model-fetch".into())
        .spawn(move || {
            match model_fetch::fetch_all(&vault, &progress) {
                Ok(model_dir) => {
                    load_model_into_registry(&model_dir, &vault);
                }
                Err(err) => {
                    eprintln!("[dome] model fetch failed: {err}");
                    log_to_fetch(&vault, &vault, &format!("ERROR fetch: {err}"));
                }
            }
            // Whether we succeeded or failed, the worker is done —
            // unblock retries from the UI.
            if let Ok(mut running) = MODEL_FETCH_RUNNING.lock() {
                *running = false;
            }
        });
}

/// JSON status snapshot for the Dome onboarding view. Always returns a
/// payload, never null — Swift uses the `ready` flag to decide whether
/// to gate embed-dependent UI behind the download panel.
///
/// Byte counts come from on-disk file sizes, not from the in-memory
/// progress object — that way a partially-downloaded model reported
/// from a previous run shows up at its real percentage instead of
/// resetting to 0% on every app restart.
#[no_mangle]
pub extern "C" fn tado_dome_model_status() -> *mut c_char {
    let vault_present = DOME_VAULT.get().cloned();
    let files_complete = vault_present
        .as_ref()
        .map(|p| model_fetch::is_complete(p))
        .unwrap_or(false);

    let snap = match (&vault_present, MODEL_PROGRESS.get()) {
        (Some(vault), Some(p)) => p.snapshot(vault),
        (Some(vault), None) => bt_core::notes::model_fetch::FetchProgress::default()
            .snapshot(vault),
        _ => bt_core::notes::model_fetch::FetchSnapshot {
            total_bytes: 0,
            downloaded_bytes: 0,
            current_file: None,
            completed: false,
            error: None,
        },
    };

    // We say `ready` when the runtime is actually attached. That's a
    // strictly stronger guarantee than "files on disk" — a corrupt
    // safetensors would let `is_complete` pass while load fails.
    let ready = bt_core::notes::embeddings::Qwen3EmbeddingProvider::default().is_runtime_loaded();

    // Surface either the fetch error or the load error, whichever is
    // present (load errors are stickier — they happen after fetch
    // completed). Loads after a successful fetch clear this slot.
    let load_err = MODEL_LOAD_ERROR
        .lock()
        .ok()
        .and_then(|g| g.clone());
    let error = snap.error.clone().or(load_err);

    let payload = json!({
        "ready": ready,
        "files_present": files_complete,
        "downloaded_bytes": snap.downloaded_bytes,
        "total_bytes": snap.total_bytes,
        "current_file": snap.current_file,
        "completed": snap.completed,
        "error": error,
    });
    to_cstr(payload.to_string())
}

/// Kick off the model download in a background thread. Idempotent —
/// repeated calls observe the same progress object. Returns 0 on
/// successful spawn (or "already running"), 2 if the daemon hasn't
/// been booted yet.
///
/// Resumable: if a previous run partially downloaded `model.safetensors`,
/// this thread sends a `Range: bytes=<existing>-` header and appends
/// rather than restarting from byte 0.
#[no_mangle]
pub extern "C" fn tado_dome_model_fetch_start() -> c_int {
    let Some(vault) = DOME_VAULT.get().cloned() else {
        return 2;
    };

    // If files are complete and the runtime is loaded, no-op.
    if model_fetch::is_complete(&vault)
        && Qwen3EmbeddingProvider::default().is_runtime_loaded()
    {
        return 0;
    }

    spawn_model_fetch(&vault);
    0
}

/// Tell Dome to load the model from a user-supplied directory (the
/// onboarding panel's "I have the file" path picker writes here when
/// the user is offline or behind a proxy). Validates that all
/// required files are present, then loads them. Returns 0 on success,
/// 2 on missing daemon, 3 on invalid path / load failure.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_model_set_path(path_cstr: *const c_char) -> c_int {
    let Some(vault) = DOME_VAULT.get().cloned() else {
        return 2;
    };
    if path_cstr.is_null() {
        return 3;
    }
    let Ok(path_str) = CStr::from_ptr(path_cstr).to_str() else {
        return 3;
    };
    let dir = Path::new(path_str.trim());
    if !dir.is_dir() {
        return 3;
    }
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
        if !dir.join(name).is_file() {
            return 3;
        }
    }
    // Persist the override so subsequent process launches skip the
    // download too. We use the env var the runtime already reads.
    std::env::set_var("TADO_DOME_EMBEDDING_MODEL_PATH", dir);
    load_model_into_registry(dir, &vault);
    if Qwen3EmbeddingProvider::default().is_runtime_loaded() {
        0
    } else {
        3
    }
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
            Ok("") => None,
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
            Ok("") => None,
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

/// Fetch recent `retrieval_log` rows for the Knowledge → System
/// surface. Optional filters: `project_id_cstr` (null = all projects),
/// `tool_cstr` (null = all tools, e.g. "dome_search"). Returns the
/// JSON envelope `{ rows, n, consumption_rate, mean_latency_ms }`.
/// Caller frees with `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_retrieval_log_recent(
    limit: c_int,
    project_id_cstr: *const c_char,
    tool_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let limit = if limit > 0 { limit as usize } else { 100 };
    match service.retrieval_log_recent(
        limit,
        optional_cstr(project_id_cstr),
        optional_cstr(tool_cstr),
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Phase 3 — supersede `old_id` with `new_id`. UI-side actor. Returns
/// the JSON envelope `{ old_id, new_id, reason }` on success, null on
/// error. Caller frees with `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_node_supersede(
    old_id_cstr: *const c_char,
    new_id_cstr: *const c_char,
    reason_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(old_id) = optional_cstr(old_id_cstr) else {
        return std::ptr::null_mut();
    };
    let Some(new_id) = optional_cstr(new_id_cstr) else {
        return std::ptr::null_mut();
    };
    let actor = bt_core::Actor::CliUser;
    match service.note_supersede(&actor, old_id, new_id, optional_cstr(reason_cstr)) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Phase 3 — confirm or dispute a graph_node. `verdict` must be
/// `'confirmed'` or `'disputed'`. Caller frees with `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_node_verify(
    node_id_cstr: *const c_char,
    verdict_cstr: *const c_char,
    agent_id_cstr: *const c_char,
    reason_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(node_id) = optional_cstr(node_id_cstr) else {
        return std::ptr::null_mut();
    };
    let Some(verdict) = optional_cstr(verdict_cstr) else {
        return std::ptr::null_mut();
    };
    let actor = bt_core::Actor::CliUser;
    match service.note_verify(
        &actor,
        node_id,
        verdict,
        optional_cstr(agent_id_cstr),
        optional_cstr(reason_cstr),
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Phase 3 — soft-archive a graph_node. Caller frees with
/// `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_node_decay(
    node_id_cstr: *const c_char,
    reason_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(node_id) = optional_cstr(node_id_cstr) else {
        return std::ptr::null_mut();
    };
    let actor = bt_core::Actor::CliUser;
    match service.node_decay(&actor, node_id, optional_cstr(reason_cstr)) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Phase 5 — seed the three default retrieval recipes
/// (architecture-review, completion-claim, team-handoff) at global
/// scope. Idempotent — re-running upserts the latest baked
/// templates without disturbing user-edited project overrides.
/// Returns the count of recipes seeded as a JSON int, or null on
/// daemon failure. Caller frees with `tado_string_free`.
#[no_mangle]
pub extern "C" fn tado_dome_recipe_seed_defaults() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.recipe_seed_defaults() {
        Ok(n) => to_cstr(serde_json::json!({ "seeded": n }).to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// v0.11 — list every retrieval recipe in the given scope. Pass
/// `scope_cstr = "global"` to see only baked defaults, `"project"`
/// to see only project-scoped overrides for the supplied
/// `project_id_cstr`. NULL `scope_cstr` means "all".
///
/// Returns JSON `{"recipes": [{recipe_id, intent_key, scope,
/// project_id, title, description, template_path, policy, enabled,
/// last_verified_at, ...}]}` or null on failure. Caller frees with
/// `tado_string_free`.
///
/// # Safety
/// Optional pointers may be null; non-null pointers must be valid
/// NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_recipe_list(
    scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let scope = optional_cstr(scope_cstr);
    let project_id = optional_cstr(project_id_cstr);
    match service.recipe_list(scope, project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// v0.11 — apply a recipe and return its `GovernedAnswer`.
/// `intent_key_cstr` must match a recipe row (e.g.
/// `"architecture-review"`). `project_id_cstr` may be null for
/// global scope.
///
/// Returns JSON `{intent_key, answer, citations: [...],
/// missing_authority: [...], policy_applied: {...}}` or null on
/// failure. Caller frees with `tado_string_free`.
///
/// # Safety
/// `intent_key_cstr` must be a non-null NUL-terminated UTF-8.
/// `project_id_cstr` may be null.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_recipe_apply(
    intent_key_cstr: *const c_char,
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if intent_key_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(intent_key) = CStr::from_ptr(intent_key_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let project_id = optional_cstr(project_id_cstr);
    let actor = swift_ui_actor();
    match service.recipe_apply(&actor, intent_key, project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

// ── v0.11 — automation surface ────────────────────────────────────
//
// Eight FFI shims that expose the in-process scheduler to the Swift
// AutomationSurface. Every shim returns JSON or null — Swift decodes
// via `DomeRpcClient.Automation` / `AutomationOccurrence`. The
// service-side methods are `automation_*` at service.rs:9663+.
//
// Operator gate: `automation_*` mutators call
// `require_operator_actor` which only blocks `Actor::Agent`.
// `swift_ui_actor()` is `Actor::UserUi` so it's allowed.

/// List every automation. Filters: `enabled_filter` (1 = only
/// enabled, 0 = only paused, -1 = both), `executor_kind_cstr` (e.g.
/// `"agent_run"`, null = all kinds), `limit` (clamped 1..500).
///
/// Returns JSON `{"automations": [...AutomationRecord]}` or null.
/// Caller frees with `tado_string_free`.
///
/// # Safety
/// `executor_kind_cstr` may be null.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_list(
    enabled_filter: c_int,
    executor_kind_cstr: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let enabled = match enabled_filter {
        1 => Some(true),
        0 => Some(false),
        _ => None,
    };
    let executor_kind = optional_cstr(executor_kind_cstr);
    let limit = limit.clamp(1, 500) as usize;
    match service.automation_list(enabled, executor_kind, limit) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Fetch one automation by id. Returns JSON `{"automation": {...}}`
/// or null when missing.
///
/// # Safety
/// `id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_get(id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.automation_get(id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Create an automation. `json_input_cstr` must be a JSON object
/// matching `automation.create`'s expected shape: at minimum
/// `{title, executor_kind, executor_config, prompt_template,
/// schedule_kind, schedule, ...}`.
///
/// Returns JSON `{"automation": {...}}` or null on failure.
///
/// # Safety
/// `json_input_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_create(
    json_input_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(input_str) = optional_cstr(json_input_cstr) else {
        return std::ptr::null_mut();
    };
    let Ok(input) = serde_json::from_str::<serde_json::Value>(input_str) else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.automation_create(&actor, input) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Update an automation. `json_patch_cstr` is a partial JSON body —
/// only fields present override the existing record.
///
/// # Safety
/// Both pointers must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_update(
    id_cstr: *const c_char,
    json_patch_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Some(patch_str) = optional_cstr(json_patch_cstr) else {
        return std::ptr::null_mut();
    };
    let Ok(patch) = serde_json::from_str::<serde_json::Value>(patch_str) else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.automation_update(&actor, id, patch) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Delete an automation. Errors with `Conflict` if the automation
/// has an active occurrence — Swift should surface the error and
/// suggest pausing first.
///
/// # Safety
/// `id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_delete(id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.automation_delete(&actor, id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Toggle pause state. `paused == 1` → calls `automation_pause`
/// (sets enabled=false, stamps paused_at). `paused == 0` →
/// `automation_resume` (sets enabled=true, clears paused_at).
///
/// # Safety
/// `id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_set_paused(
    id_cstr: *const c_char,
    paused: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    let result = if paused != 0 {
        service.automation_pause(&actor, id)
    } else {
        service.automation_resume(&actor, id)
    };
    match result {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Manually enqueue an occurrence right now (the "Run now" button).
/// Returns JSON `{"occurrence": {...}}` or null on conflict (serial
/// automation already has an active occurrence).
///
/// # Safety
/// `id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_run_now(id_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.automation_enqueue_now(&actor, id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List occurrences. Pass `automation_id_cstr` to scope to one
/// automation, or null for the global ledger across all
/// automations. `status_cstr` filters by status string (`ready`,
/// `running`, `done`, `failed`, ...). `from_cstr`/`to_cstr` are
/// optional RFC3339 timestamps.
///
/// # Safety
/// All pointers may be null. `limit` clamped 1..500.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_occurrence_list(
    automation_id_cstr: *const c_char,
    status_cstr: *const c_char,
    from_cstr: *const c_char,
    to_iso_cstr: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let automation_id = optional_cstr(automation_id_cstr);
    let status = optional_cstr(status_cstr);
    let from = optional_cstr(from_cstr);
    let to_iso = optional_cstr(to_iso_cstr);
    let limit = limit.clamp(1, 500) as usize;
    match service.automation_occurrence_list(automation_id, status, from, to_iso, limit) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Retry a failed/cancelled occurrence (the "Retry" button on a
/// failed occurrence row).
///
/// # Safety
/// `occurrence_id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_automation_retry_occurrence(
    occurrence_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if occurrence_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(id) = CStr::from_ptr(occurrence_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.automation_retry_occurrence(&actor, id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

// ── v0.12 — system observability + audit + eval ───────────────────

/// JSON shape: `{checks: [{name, ok, detail}, ...], db_ok, ...}`.
/// The Knowledge → System surface renders one row per check.
#[no_mangle]
pub extern "C" fn tado_dome_system_health() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.system_health() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// JSON shape: `{queue_depth: {ready, scheduled, active}, stale_leases,
/// workers: [...]}`. Used by the System surface "Scheduler" card.
#[no_mangle]
pub extern "C" fn tado_dome_system_automation_status() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.system_automation_status() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// JSON shape: `{ok: bool, ...}` — connectors, openclaw, and
/// runtime-status helpers folded into one payload so the System
/// surface gets everything in one round trip.
#[no_mangle]
pub extern "C" fn tado_dome_system_runtime_envelope() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let connectors = service.system_connector_status().ok();
    let openclaw = service.system_openclaw_status().ok();
    let runtime = service.system_runtime_status(None).ok();
    let value = serde_json::json!({
        "connectors": connectors,
        "openclaw": openclaw,
        "runtime": runtime,
    });
    to_cstr(value.to_string())
}

/// Tail the audit log. `since_cstr` may be null (= start from
/// origin). `limit` clamped 1..1000.
///
/// Returns JSON `{"entries": [{action, actor_kind, actor_id,
/// created_at, params, result, ...}, ...]}` or null on failure.
///
/// # Safety
/// `since_cstr` may be null; non-null must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_audit_tail(
    since_cstr: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let since = optional_cstr(since_cstr);
    let limit = limit.clamp(1, 1000) as usize;
    match service.audit_tail(since, limit) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Run `dome-eval replay` in-process. `vault_db_cstr` is the
/// absolute path to `<vault>/.bt/index.sqlite` (Swift can resolve
/// via `StorePaths`). `since_seconds <= 0` → every row.
///
/// Returns JSON serialization of the `ReplayReport` (window_start,
/// window_end, n_rows, consumption_rate, mean_latency_ms,
/// aggregate, rows). Caller frees with `tado_string_free`.
///
/// # Safety
/// `vault_db_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_eval_replay(
    vault_db_cstr: *const c_char,
    since_seconds: i64,
) -> *mut c_char {
    if vault_db_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(path_str) = CStr::from_ptr(vault_db_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let path = std::path::Path::new(path_str);
    match dome_eval::replay_for_vault(path, since_seconds) {
        Ok(report) => match serde_json::to_string(&report) {
            Ok(json) => to_cstr(json),
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

// ── v0.13 — bulk import + vault status + tokens ───────────────────

/// Vault status snapshot — `vault_path`, `doc_count`,
/// `topics_count`, `socket_path`, `tasks_file`. Used by the
/// Knowledge → System "Vault status" header card.
#[no_mangle]
pub extern "C" fn tado_dome_vault_status() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.status() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Walk `root_path` (must already live inside the vault) and list
/// every importable file. `root_path_cstr = null` → scan the whole
/// vault root. Returns JSON `{root_path, items: [...], count,
/// skipped: [...]}` mirroring `service.import_preview`.
///
/// # Safety
/// `root_path_cstr` may be null.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_import_preview(
    root_path_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let root_path = optional_cstr(root_path_cstr);
    match service.import_preview(root_path) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Execute the import. `items_json_cstr` is a JSON array of
/// `ImportPreviewItem` shapes (the Swift wizard echoes back
/// whatever subset of `import_preview.items` the user checked).
///
/// Returns JSON `{imported: [...], failures: [...], count}` or
/// null on failure.
///
/// # Safety
/// `items_json_cstr` must be non-null NUL-terminated UTF-8 holding
/// a JSON array.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_import_execute(
    items_json_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(json_str) = optional_cstr(items_json_cstr) else {
        return std::ptr::null_mut();
    };
    let Ok(items): Result<Vec<bt_core::service::ImportPreviewItem>, _> =
        serde_json::from_str(json_str)
    else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.import_execute(&actor, &items) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List every issued agent token. Returns JSON `{tokens: [{token_id,
/// agent_name, caps, created_at, last_used_at, revoked}, ...]}`.
#[no_mangle]
pub extern "C" fn tado_dome_token_list() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.token_list() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Issue a new token. `caps_csv_cstr` is a comma-separated list
/// of capability names (`search,read,note,schedule,recipe,...`).
/// Returns JSON `{token, token_id, agent_name, caps}` — the
/// `token` field is the one-time secret the operator must copy
/// before closing the dialog.
///
/// # Safety
/// Both pointers must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_token_create(
    agent_name_cstr: *const c_char,
    caps_csv_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if agent_name_cstr.is_null() || caps_csv_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(agent_name) = CStr::from_ptr(agent_name_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(caps_csv) = CStr::from_ptr(caps_csv_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let caps: Vec<String> = caps_csv
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    match service.token_create(agent_name, caps) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Rotate a token's secret. Returns the new raw secret and the
/// token_id; old secret is invalidated immediately.
///
/// # Safety
/// `token_id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_token_rotate(
    token_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if token_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(token_id) = CStr::from_ptr(token_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.token_rotate(token_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Revoke a token. The token row stays in the config (audit trail)
/// but `revoked = true` so authentication fails.
///
/// # Safety
/// `token_id_cstr` must be non-null NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_token_revoke(
    token_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if token_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(token_id) = CStr::from_ptr(token_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.token_revoke(token_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Phase 4 — compose the spawn-time preamble in Rust. Byte-equivalent
/// to `Sources/Tado/Extensions/Dome/DomeContextPreamble.swift`'s
/// `build(for:)` once the Swift composer adopts the deterministic
/// relative-time formatter. JSON request body shape:
///
/// ```json
/// {
///   "agent_name":   "backend",
///   "project_name": "Tado",
///   "project_id":   "11111111-…",
///   "project_root": "/Users/miguel/Documents/tado",
///   "team_name":    "core",
///   "teammates":    ["frontend"]
/// }
/// ```
///
/// Returns the rendered preamble as a heap-allocated UTF-8 string, or
/// null when there's nothing to render. Caller frees with
/// `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_compose_spawn_preamble(
    json_args_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(json_str) = optional_cstr(json_args_cstr) else {
        return std::ptr::null_mut();
    };
    let value: serde_json::Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let teammates = value
        .get("teammates")
        .and_then(serde_json::Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let rendered = service.spawn_pack_get_or_build(
        value.get("agent_name").and_then(serde_json::Value::as_str),
        value.get("project_name").and_then(serde_json::Value::as_str),
        value.get("project_id").and_then(serde_json::Value::as_str),
        value.get("project_root").and_then(serde_json::Value::as_str),
        value.get("team_name").and_then(serde_json::Value::as_str),
        teammates,
    );
    match rendered {
        Ok(Some(s)) => to_cstr(s),
        _ => std::ptr::null_mut(),
    }
}

/// Phase 3 — read enrichment queue depth for the Knowledge → System
/// backfill chip. Returns `{ queued, running, done, failed }` JSON.
#[no_mangle]
pub extern "C" fn tado_dome_enrichment_queue_depth() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let conn = match service.open_conn_for_ffi() {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };
    match bt_core::enrichment::queue_depth(&conn) {
        Ok(depth) => match serde_json::to_string(&depth) {
            Ok(s) => to_cstr(s),
            Err(_) => std::ptr::null_mut(),
        },
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

/// Resolve the latest context pack for a brand/session/doc tuple.
/// Wraps `service.context_resolve(...)`. Returns the JSON envelope
/// bt-core produces, or null on daemon-down / failure. Caller frees
/// with `tado_string_free`.
///
/// All pointers are optional. At least one of `brand_cstr` or
/// `session_id_cstr`/`doc_id_cstr` will typically be set; passing all
/// nil returns whatever pack the brand-default lookup finds.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_context_resolve(
    brand_cstr: *const c_char,
    session_id_cstr: *const c_char,
    doc_id_cstr: *const c_char,
    mode_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.context_resolve(
        optional_cstr(brand_cstr),
        optional_cstr(session_id_cstr),
        optional_cstr(doc_id_cstr),
        optional_cstr(mode_cstr),
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Compact a brand/session/doc context pack via
/// `service.context_compact(...)`. Caller passes `force=true` to
/// rebuild even if the source hash hasn't changed. Returns the
/// produced manifest JSON or null on failure. Caller frees with
/// `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_context_compact(
    brand_cstr: *const c_char,
    session_id_cstr: *const c_char,
    doc_id_cstr: *const c_char,
    force: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let Some(brand) = optional_cstr(brand_cstr) else {
        return std::ptr::null_mut();
    };
    let actor = swift_ui_actor();
    match service.context_compact(
        &actor,
        brand,
        optional_cstr(session_id_cstr),
        optional_cstr(doc_id_cstr),
        force,
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

/// Trigger `vault.reindex` — re-runs every doc through the live
/// embedder, upgrading legacy `noop@1` chunks to the current Qwen3
/// model. Long-running (30-60s on 1000 notes); Swift dispatches via
/// `Task.detached` to keep the UI responsive.
///
/// Returns `{"ok": true}` on success or null on failure. Caller frees
/// via `tado_string_free`.
#[no_mangle]
pub extern "C" fn tado_dome_vault_reindex() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.reindex() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Snapshot of `note_chunks` rows grouped by embedding model. Used by
/// the Knowledge → Agent System "Embeddings" panel to show how many
/// chunks are still on legacy embeddings.
///
/// Returns JSON `{"model_counts": { "<id>@<version>": <count>, ... },
/// "total": <count>}` or null on failure.
#[no_mangle]
pub extern "C" fn tado_dome_vault_embedding_stats() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.vault_embedding_stats() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Recursively ingest a directory as Dome notes. One note per
/// eligible file, capped at 5000 (`capped: true` in the result if hit).
///
/// Returns JSON `{"created": N, "skipped": M, "capped": <bool>}` or
/// null on failure.
///
/// # Safety
/// `path_cstr` must be a NUL-terminated UTF-8 string. The optional
/// pointers (`topic`, `project_id`, `project_root`) may be null.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_vault_ingest_path(
    path_cstr: *const c_char,
    topic_cstr: *const c_char,
    owner_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
    project_root_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if path_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(path_str) = CStr::from_ptr(path_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let owner_scope = optional_cstr(owner_scope_cstr).unwrap_or("global");
    let topic = optional_cstr(topic_cstr);
    let project_id = optional_cstr(project_id_cstr);
    let project_root = optional_cstr(project_root_cstr).map(Path::new);
    let actor = swift_ui_actor();

    match service.vault_ingest_path(
        &actor,
        Path::new(path_str),
        topic,
        owner_scope,
        project_id,
        project_root,
    ) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Read-only count of docs that `tado_dome_vault_purge_topic_scope`
/// would delete. Used by the Swift confirmation dialog so the operator
/// sees the exact number before confirming. Returns JSON
/// `{"count": N, "topic": ..., "owner_scope": ..., "project_id": ...}`
/// or null on failure.
///
/// # Safety
/// `topic_cstr` and `owner_scope_cstr` must be NUL-terminated UTF-8.
/// `project_id_cstr` may be null (matches docs.project_id IS NULL).
#[no_mangle]
pub unsafe extern "C" fn tado_dome_vault_purge_topic_scope_count(
    topic_cstr: *const c_char,
    owner_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if topic_cstr.is_null() || owner_scope_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(topic) = CStr::from_ptr(topic_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(owner_scope) = CStr::from_ptr(owner_scope_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let project_id = optional_cstr(project_id_cstr);

    match service.vault_purge_topic_scope_count(topic, owner_scope, project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Bulk-delete every doc matching `(topic, owner_scope, project_id?)`
/// along with cascade rows (`note_chunks`, `doc_meta`, `fts_notes`,
/// `graph_nodes`, `graph_edges`) and the on-disk `topics/<topic>/<slug>/`
/// folders. Used by the Knowledge → Agent System "Clear globally-
/// ingested codebases" button to undo a misclicked global ingestion in
/// one shot.
///
/// `project_id_cstr` may be null — that matches `docs.project_id IS NULL`
/// (every owner_scope='global' row stores NULL there).
///
/// Returns JSON `{"purged": N, "topic": ..., "owner_scope": ...,
/// "project_id": ...}` or null on failure.
///
/// # Safety
/// Same as `_count` above. Caller frees with `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_vault_purge_topic_scope(
    topic_cstr: *const c_char,
    owner_scope_cstr: *const c_char,
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if topic_cstr.is_null() || owner_scope_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(topic) = CStr::from_ptr(topic_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(owner_scope) = CStr::from_ptr(owner_scope_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let project_id = optional_cstr(project_id_cstr);
    let actor = swift_ui_actor();

    match service.vault_purge_topic_scope(&actor, topic, owner_scope, project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Live snapshot of legacy `vault_ingest_path` progress. Caller frees
/// the returned C string with `tado_string_free`. Always returns a
/// JSON object — null only if the daemon hasn't booted.
///
/// JSON shape: `{ running, created, skipped, total, canceled }`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_vault_ingest_progress() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    to_cstr(service.vault_ingest_progress().to_string())
}

/// Request that the in-flight ingest stop at the next file boundary.
/// Returns 1 if an ingest was running, 0 otherwise. Idempotent.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_vault_ingest_cancel() -> c_int {
    let Some(service) = DOME_SERVICE.get() else {
        return 0;
    };
    if service.vault_ingest_cancel() {
        1
    } else {
        0
    }
}

// ── Phase 2: code-indexing FFI ───────────────────────────────────
//
// These shims surface the `code.*` RPCs to Swift without the
// Unix-socket round-trip the MCP path uses. Long-running calls
// (`code.index_project` walks tens of thousands of files) MUST be
// invoked from a Swift `Task.detached` — they block the calling
// thread until the index finishes.

/// Register a project for code indexing. Idempotent.
///
/// Returns JSON `{ ok, project_id, name, root_path, enabled }` or
/// null on failure. Caller frees with `tado_string_free`.
///
/// # Safety
/// All pointers must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_register_project(
    project_id_cstr: *const c_char,
    name_cstr: *const c_char,
    root_path_cstr: *const c_char,
    enabled: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() || name_cstr.is_null() || root_path_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(name) = CStr::from_ptr(name_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let Ok(root_path) = CStr::from_ptr(root_path_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_register_project(project_id, name, root_path, enabled) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Unregister a project from code indexing. With `purge=true`,
/// deletes every chunk row for the project too.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_unregister_project(
    project_id_cstr: *const c_char,
    purge: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_unregister_project(project_id, purge) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List every registered code project plus per-project file/chunk
/// counts. Used by Settings → Code Indexing.
#[no_mangle]
pub extern "C" fn tado_dome_code_list_projects() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.code_list_projects() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Run a full code index. Blocks for the duration of the walk +
/// embed (minutes for a multi-thousand-file project). Swift MUST
/// invoke from `Task.detached`.
///
/// Returns the `IndexResult` JSON on success or null on failure.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_index_project(
    project_id_cstr: *const c_char,
    full_rebuild: bool,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_index_project(project_id, full_rebuild) {
        Ok(value) => to_cstr(value.to_string()),
        Err(err) => {
            eprintln!("[dome] code_index_project failed: {err}");
            std::ptr::null_mut()
        }
    }
}

/// Start a file watcher for a registered project. Idempotent — a
/// second call replaces the existing watcher for the same project.
/// The watcher debounces 500 ms and incrementally re-embeds changed
/// files via the same `replace_chunks_for_file` path the full
/// indexer uses.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_watch_start(
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_watch_start(project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(err) => {
            eprintln!("[dome] code_watch_start failed: {err}");
            std::ptr::null_mut()
        }
    }
}

/// Stop the file watcher for a project. No-op if no watcher was
/// running. Returns `{ ok, project_id, watching: false, had_watcher }`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_watch_stop(
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_watch_stop(project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List every project_id with an active watcher.
#[no_mangle]
pub extern "C" fn tado_dome_code_watch_list() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.code_watch_list() {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Reattach watchers for every `enabled=1` project. Called on app
/// boot from `tado_dome_start` and on `AppSettings.codeIndexingEnabled`
/// flipping back to `true` from Swift. Idempotent — projects that
/// already have a watcher are skipped.
#[no_mangle]
pub extern "C" fn tado_dome_code_watch_resume_all() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    match service.code_resume_watchers() {
        Ok(value) => to_cstr(value.to_string()),
        Err(err) => {
            eprintln!("[dome] watch_resume_all failed: {err}");
            std::ptr::null_mut()
        }
    }
}

/// Stop every active watcher in one call. Used when the per-user
/// kill switch flips off or before vault relocation.
#[no_mangle]
pub extern "C" fn tado_dome_code_watch_stop_all() -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    let stopped = service.code_watchers_stop_all_handle();
    to_cstr(serde_json::json!({ "ok": true, "stopped": stopped }).to_string())
}

/// Hybrid search across the indexed code chunks.
///
/// Accepts a JSON envelope so the FFI signature stays stable as we
/// add more knobs (project filter, language filter, alpha):
///
/// ```json
/// {
///   "query": "where do we spawn the PTY",
///   "project_ids": ["tado"],
///   "languages": ["rust", "swift"],
///   "limit": 25,
///   "alpha": 0.6
/// }
/// ```
///
/// Returns the bt-core `code.search` payload as JSON, or null on
/// failure. Caller frees with `tado_string_free`.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_search(query_json_cstr: *const c_char) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if query_json_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(json_str) = CStr::from_ptr(query_json_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    let value: serde_json::Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    match service.handle_rpc("code.search", value) {
        Ok(result) => to_cstr(result.to_string()),
        Err(err) => {
            eprintln!("[dome] code_search failed: {err}");
            std::ptr::null_mut()
        }
    }
}

/// Read the live progress snapshot for an in-flight index. Cheap;
/// safe to poll from the main thread every 250 ms.
#[no_mangle]
pub unsafe extern "C" fn tado_dome_code_index_status(
    project_id_cstr: *const c_char,
) -> *mut c_char {
    let Some(service) = DOME_SERVICE.get() else {
        return std::ptr::null_mut();
    };
    if project_id_cstr.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(project_id) = CStr::from_ptr(project_id_cstr).to_str() else {
        return std::ptr::null_mut();
    };
    match service.code_index_status(project_id) {
        Ok(value) => to_cstr(value.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
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
