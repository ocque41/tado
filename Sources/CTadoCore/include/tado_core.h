#ifndef TADO_CORE_H
#define TADO_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define ATTR_BOLD (1 << 0)

#define ATTR_ITALIC (1 << 1)

#define ATTR_UNDERLINE (1 << 2)

#define ATTR_REVERSE (1 << 3)

#define ATTR_STRIKETHROUGH (1 << 4)

#define ATTR_DIM (1 << 5)

/**
 * Left half of a 2-cell-wide glyph (CJK, some box-drawing). The
 * renderer extends this cell's quad to span two columns. Mutually
 * exclusive with ATTR_WIDE_FILLER on any cell.
 */
#define ATTR_WIDE (1 << 6)

/**
 * Right half of a 2-cell-wide glyph. `ch` is 0. Shader skips
 * rasterization for these cells — the WIDE-start quad already
 * covers the pixels.
 */
#define ATTR_WIDE_FILLER (1 << 7)

typedef struct TadoSession {
  uint8_t _priv[0];
} TadoSession;

/**
 * Key-value pair for env vars. Both strings must be null-terminated UTF-8.
 */
typedef struct TadoEnvPair {
  const char *key;
  const char *value;
} TadoEnvPair;

typedef struct TadoSnapshot {
  uint8_t _priv[0];
} TadoSnapshot;

/**
 * Raw cell view for the Swift side. Matches the layout of `grid::Cell`
 * exactly (same `#[repr(C)]`, same field order).
 */
typedef struct TadoCell {
  uint32_t ch;
  uint32_t fg;
  uint32_t bg;
  uint32_t attrs;
} TadoCell;

typedef struct TadoScrollback {
  uint8_t _priv[0];
} TadoScrollback;

/**
 * Opaque return: spawn a session. Returns null on failure.
 *
 * # Safety
 * All pointers must point at valid null-terminated UTF-8 (or be null where
 * annotated below). `argv` and `env` arrays are read up to their counts.
 */
struct TadoSession *tado_session_spawn(const char *cmd,
                                       const char *const *argv,
                                       uintptr_t argc,
                                       const char *cwd,
                                       const struct TadoEnvPair *env,
                                       uintptr_t env_count,
                                       uint16_t cols,
                                       uint16_t rows);

/**
 * Pull+clear the last spawn error recorded on the current thread. Returns
 * a malloc'd CString (caller frees with `tado_string_free`) or null if no
 * error is pending. Always called from Swift immediately after
 * `tado_session_spawn` returns null, so the thread-local-per-call contract
 * holds: the spawn call ran on this thread, so the error is here too.
 */
char *tado_last_spawn_error(void);

/**
 * Drop a session handle. Safe to call with null (no-op).
 */
void tado_session_release(struct TadoSession *session);

/**
 * Write raw bytes to the session's PTY (keyboard input). Returns bytes written,
 * or -1 on error.
 */
intptr_t tado_session_write(struct TadoSession *session, const uint8_t *bytes, uintptr_t len);

/**
 * Resize the PTY and grid.
 */
void tado_session_resize(struct TadoSession *session, uint16_t cols, uint16_t rows);

/**
 * Set the default fg/bg colors used for blank cells and after SGR
 * reset. RGBA is packed `0xRRGGBBAA` — same encoding as `TadoCell.fg/bg`.
 */
void tado_session_set_default_colors(struct TadoSession *session, uint32_t fg, uint32_t bg);

/**
 * Replace the 16-slot ANSI palette consulted by SGR 30..=37/40..=47
 * (normal, slots 0..=7) and 90..=97/100..=107 (bright, slots 8..=15).
 * `palette` must point to 16 `uint32_t` RGBA values. No-op on null.
 */
void tado_session_set_ansi_palette(struct TadoSession *session, const uint32_t *palette);

/**
 * Kill the child process (SIGTERM-ish; exact semantics depend on OS).
 */
void tado_session_kill(struct TadoSession *session, int32_t signal);

/**
 * 1 if the child is still running, 0 otherwise.
 */
uint8_t tado_session_is_running(struct TadoSession *session);

/**
 * 1 if the PTY has bracketed paste mode enabled (DECSET 2004).
 */
uint8_t tado_session_bracketed_paste(struct TadoSession *session);

/**
 * 1 if the PTY has DECCKM application cursor mode enabled (DECSET 1).
 * The Swift keymap reads this to emit SS3-prefixed arrows (ESC O A …)
 * instead of CSI-prefixed (ESC [ A …) when true.
 */
uint8_t tado_session_application_cursor(struct TadoSession *session);

/**
 * Mouse reporting mode: 0 off, 1 button, 2 drag. Use
 * `tado_session_mouse_sgr` to determine the encoding.
 */
uint8_t tado_session_mouse_mode(struct TadoSession *session);

/**
 * 1 if the PTY uses SGR (1006) mouse encoding — modern, column-uncapped.
 */
uint8_t tado_session_mouse_sgr(struct TadoSession *session);

/**
 * Pull the latest title emitted since the last call. Returns a malloc'd
 * C string (caller frees with `tado_string_free`) or null if there's
 * been no title since the last drain.
 */
char *tado_session_take_title(struct TadoSession *session);

/**
 * Pull + clear the pending bell count. Returns 0 when no bells have
 * arrived since the last call. Swift's draw loop reads this each
 * idle-tick and rings NSBeep when non-zero.
 */
uint32_t tado_session_take_bell_count(struct TadoSession *session);

/**
 * Free a string returned by `tado_session_take_title` (or any other
 * Rust-side CString). No-op on null.
 */
void tado_string_free(char *s);

/**
 * Snapshot just the dirty rows since the last snapshot call.
 */
struct TadoSnapshot *tado_session_snapshot_dirty(struct TadoSession *session);

/**
 * Snapshot the entire grid (use for initial upload / resize).
 */
struct TadoSnapshot *tado_session_snapshot_full(struct TadoSession *session);

/**
 * Capture the current live grid into the session's viewport history
 * ring buffer. Intended to be called at ~2 fps from the Swift render
 * loop; see `Session::capture_viewport_frame`.
 */
void tado_session_capture_viewport_frame(struct TadoSession *session);

/**
 * Number of frames currently buffered in viewport history.
 */
uint32_t tado_session_viewport_frame_count(struct TadoSession *session);

/**
 * Snapshot a single historical frame, `offset` frames back from the
 * newest (offset 1 = previous frame). Returns null past the end of
 * history or when offset == 0. Caller must free with
 * `tado_snapshot_free` when done.
 */
struct TadoSnapshot *tado_session_viewport_frame_snapshot(struct TadoSession *session,
                                                          uint32_t offset);

uint16_t tado_snapshot_cols(struct TadoSnapshot *snap);

uint16_t tado_snapshot_rows(struct TadoSnapshot *snap);

uint16_t tado_snapshot_cursor_x(struct TadoSnapshot *snap);

uint16_t tado_snapshot_cursor_y(struct TadoSnapshot *snap);

/**
 * 1 if the cursor should be rendered, 0 if hidden by DECTCEM (CSI ?25l).
 */
uint8_t tado_snapshot_cursor_visible(struct TadoSnapshot *snap);

uintptr_t tado_snapshot_dirty_row_count(struct TadoSnapshot *snap);

/**
 * Pointer to the dirty row indices (u16). Lives as long as the snapshot.
 */
const uint16_t *tado_snapshot_dirty_rows(struct TadoSnapshot *snap);

/**
 * Pointer to the packed cell buffer. Length is
 * `dirty_row_count * cols`. Lives as long as the snapshot.
 */
const struct TadoCell *tado_snapshot_cells(struct TadoSnapshot *snap);

uintptr_t tado_snapshot_cells_len(struct TadoSnapshot *snap);

void tado_snapshot_free(struct TadoSnapshot *snap);

/**
 * Snapshot `rows` lines of scrollback starting `offset` lines back from the
 * most-recently-evicted line. Oldest line first inside the returned cell
 * buffer. Caller must free with `tado_scrollback_free`.
 */
struct TadoScrollback *tado_session_scrollback(struct TadoSession *session,
                                               uintptr_t offset,
                                               uintptr_t rows);

uint16_t tado_scrollback_cols(struct TadoScrollback *snap);

uint16_t tado_scrollback_rows(struct TadoScrollback *snap);

const struct TadoCell *tado_scrollback_cells(struct TadoScrollback *snap);

uintptr_t tado_scrollback_cells_len(struct TadoScrollback *snap);

/**
 * Total scrollback lines currently buffered (independent of the most recent
 * snapshot window). Useful for scrollbar sizing.
 */
uint32_t tado_scrollback_total_available(struct TadoScrollback *snap);

void tado_scrollback_free(struct TadoScrollback *snap);

/**
 * Drop a message envelope into Tado's external IPC inbox. Used by
 * non-Swift callers that want to reach a running Tado instance via
 * the same contract Dome's Copy-to-Tado extension uses.
 *
 * `target_uuid_cstr` is the destination session id as a UTF-8
 * hyphenated UUID string. `body_cstr` is the message body (UTF-8).
 * `from_name_cstr` is the human-readable sender label.
 *
 * # Safety
 * All `*const c_char` arguments must point to NUL-terminated UTF-8
 * strings.
 */
int tado_ipc_send_external_message(const char *target_uuid_cstr,
                                   const char *body_cstr,
                                   const char *from_name_cstr);

/**
 * Read Tado's session registry (`/tmp/tado-ipc/registry.json`) and
 * return the JSON contents as a heap-allocated C string. Returns
 * `null` if the file is missing or unreadable.
 *
 * Caller frees with [`tado_string_free`].
 */
char *tado_ipc_read_registry_json(void);

/**
 * A1 slice 1 — Write Tado's session registry through Rust.
 *
 * Takes a pre-serialized JSON array of `IpcSessionEntry` (the
 * exact shape Swift's `IPCBroker.updateRegistry` already produces),
 * parses + validates it in Rust, and re-emits it through
 * `tado_ipc::write_registry`, which enforces the Swift-pretty byte
 * layout + atomic replace (tmp + rename).
 *
 * Going through Rust lets external consumers (future CLI in Rust,
 * Dome's Copy-to-Tado extension) reuse the same serializer Swift
 * writes with, which matters the day Swift migrates off
 * `JSONEncoder.prettyPrinted` and we need a single place to track
 * the format. Returns 0 on success, 2 on JSON parse failure, 3 on
 * IO error, 255 on any other path.
 *
 * `root_cstr` may be null to mean `/tmp/tado-ipc` (stable symlink);
 * otherwise it's the IPC root (e.g. `/tmp/tado-ipc-<pid>`).
 *
 * # Safety
 * `json_cstr` must be a NUL-terminated UTF-8 string. `root_cstr`
 * must be null or a NUL-terminated UTF-8 string.
 */
int tado_ipc_write_registry_json(const char *root_cstr, const char *json_cstr);

/**
 * Start the real-time A2A event socket (A6). Binds a Unix-domain
 * socket at `socket_path_cstr` and keeps it serving for the rest of
 * the process lifetime. Idempotent — a second call is a silent
 * no-op that still returns 0.
 *
 * If `socket_path_cstr` is null, defaults to the stable IPC root's
 * `events.sock` (i.e. `/tmp/tado-ipc/events.sock`). Swift normally
 * passes `/tmp/tado-ipc-<pid>/events.sock` so the per-PID directory
 * created by `IPCBroker` owns the file.
 *
 * Returns 0 on success, 2 on invalid UTF-8 in the path, 3 on IO
 * error (dir creation or bind).
 *
 * # Safety
 * `socket_path_cstr` must be null or point to a NUL-terminated UTF-8
 * string naming a writable location whose parent directory either
 * exists or can be created.
 */
int tado_events_start(const char *socket_path_cstr);

/**
 * Publish an event onto the real-time socket started by
 * [`tado_events_start`]. Silently dropped if the server hasn't been
 * started yet; callers don't need to check — the Swift `EventBus`
 * deliverer is registered after the start call at app launch.
 *
 * `kind_cstr` is the event kind (`terminal.spawned`, `topic:planning`,
 * `spawn.requested`, etc.). `payload_json_cstr` is a JSON object
 * string carrying the event's data; invalid JSON is replaced with
 * an empty object so a malformed publish can't crash the bridge.
 *
 * Returns 0 on success, 2 on invalid UTF-8 in either argument.
 *
 * # Safety
 * Both pointers must be NUL-terminated UTF-8 strings.
 */
int tado_events_publish(const char *kind_cstr, const char *payload_json_cstr);

/**
 * Atomic-write a JSON-encoded payload to `path_cstr`. The payload
 * is parsed via `serde_json` and pretty-printed via tado-settings's
 * `write_json` (temp + sync + rename).
 *
 * Returns 0 on success, 2 on JSON parse failure, 3 on IO error.
 *
 * # Safety
 * Both pointers must be valid NUL-terminated UTF-8 strings.
 */
int tado_settings_write_json(const char *path_cstr, const char *json_cstr);

/**
 * Read a JSON file into a heap-allocated C string. Returns null
 * on missing file (caller treats as scope-empty). Caller frees
 * with [`tado_string_free`].
 *
 * # Safety
 * `path_cstr` must be a valid NUL-terminated UTF-8 string.
 */
char *tado_settings_read_json(const char *path_cstr);

/**
 * Boot Dome's in-process daemon against the given vault path.
 *
 * Creates a dedicated multi-threaded Tokio runtime (2 worker threads,
 * enough for the scheduler tick + per-connection handler pattern
 * Dome uses) and spawns `bt_core::rpc::run_daemon` on it. The
 * daemon binds a Unix socket inside the vault at
 * `<vault>/.bt/bt-core.sock` that `dome-mcp` and the Swift Dome
 * surfaces connect to.
 *
 * Idempotent: a second call with any vault path is a no-op and
 * returns 0. (Dome only supports one vault per app lifetime; vault
 * switching isn't planned for v0.)
 *
 * # Safety
 * `vault_cstr` must point to a NUL-terminated UTF-8 string naming a
 * writable directory (or one we can create).
 */
int tado_dome_start(const char *vault_cstr);

/**
 * JSON status snapshot for the Dome onboarding view. Always returns a
 * payload, never null — Swift uses the `ready` flag to decide whether
 * to gate embed-dependent UI behind the download panel.
 *
 * Byte counts come from on-disk file sizes, not from the in-memory
 * progress object — that way a partially-downloaded model reported
 * from a previous run shows up at its real percentage instead of
 * resetting to 0% on every app restart.
 */
char *tado_dome_model_status(void);

/**
 * Kick off the model download in a background thread. Idempotent —
 * repeated calls observe the same progress object. Returns 0 on
 * successful spawn (or "already running"), 2 if the daemon hasn't
 * been booted yet.
 *
 * Resumable: if a previous run partially downloaded `model.safetensors`,
 * this thread sends a `Range: bytes=<existing>-` header and appends
 * rather than restarting from byte 0.
 */
int tado_dome_model_fetch_start(void);

/**
 * Tell Dome to load the model from a user-supplied directory (the
 * onboarding panel's "I have the file" path picker writes here when
 * the user is offline or behind a proxy). Validates that all
 * required files are present, then loads them. Returns 0 on success,
 * 2 on missing daemon, 3 on invalid path / load failure.
 */
int tado_dome_model_set_path(const char *path_cstr);

/**
 * Shut down the Dome daemon.
 *
 * Phase-2 stub: the OS reclaims the runtime on app exit and the
 * socket file is removed on next start (bt-core unlinks before
 * bind). A real graceful-shutdown implementation would signal the
 * RPC loop to stop accepting + drain in-flight handlers, but that's
 * not needed for Phase-2 verification.
 */
int tado_dome_stop(void);

/**
 * Issue a fresh Dome agent token for an MCP caller.
 *
 * Wraps `CoreService::token_create(agent_name, caps)` — mints a
 * token, persists it to `<vault>/.bt/config.toml`, and returns the
 * raw token value as a heap-allocated C string for the caller to
 * pass verbatim to `claude mcp add`. Caller frees with
 * `tado_string_free`.
 *
 * `caps_csv` is a comma-separated list of capability names
 * (e.g. `"search,read,note,schedule"` for the default dome-mcp
 * surface). Whitespace is trimmed per entry; empty entries are
 * skipped. A null pointer is treated as "no caps" which bt-core
 * interprets as full agent scope.
 *
 * Returns null on any failure (FFI convention matches the other
 * Dome shims). Failure reasons:
 * - Vault not open (caller didn't run `tado_dome_start` first, or
 *   it failed to open)
 * - agent_name not valid UTF-8 or null
 * - bt-core rejected the token (e.g. vault write failure)
 *
 * # Safety
 * `agent_name_cstr` must point to a NUL-terminated UTF-8 string.
 * `caps_csv_cstr` must be either null or a NUL-terminated UTF-8
 * string.
 */
char *tado_dome_issue_token(const char *agent_name_cstr, const char *caps_csv_cstr);

/**
 * Create a new Dome note and write its body.
 *
 * Params:
 * - `scope_cstr`: `"user"` writes to `user.md`; `"agent"` writes to
 *   `agent.md`. Anything else → null return.
 * - `topic_cstr`: slug-safe topic (e.g. `"user"` for the User Notes
 *   tab, `"project:abc123"` for project-scoped notes). bt-core
 *   sanitizes; spaces → dashes.
 * - `title_cstr`: human-readable title. Doubles as the slug if no
 *   explicit slug is passed (none is).
 * - `body_cstr`: markdown body to write (replace mode, so previous
 *   content if any is overwritten).
 *
 * Returns a heap-allocated JSON string `{"id": "<uuid>"}` on success
 * or null on any failure. Caller frees with `tado_string_free`.
 *
 * # Safety
 * All pointers must be NUL-terminated UTF-8.
 */
char *tado_dome_note_write(const char *scope_cstr,
                           const char *topic_cstr,
                           const char *title_cstr,
                           const char *body_cstr);

/**
 * Create a scoped Dome knowledge note and write its body.
 */
char *tado_dome_note_write_scoped(const char *note_scope_cstr,
                                  const char *topic_cstr,
                                  const char *title_cstr,
                                  const char *body_cstr,
                                  const char *owner_scope_cstr,
                                  const char *project_id_cstr,
                                  const char *project_root_cstr,
                                  const char *knowledge_kind_cstr);

/**
 * Replace the user side of an existing note.
 */
char *tado_dome_note_update_user(const char *id_cstr, const char *body_cstr);

/**
 * Update only the display title of an existing note.
 */
char *tado_dome_note_rename_title(const char *id_cstr, const char *title_cstr);

/**
 * List notes filtered by topic (or all if topic is null/empty).
 *
 * Params:
 * - `topic_cstr`: topic slug to filter by, or null to list every
 *   note in the vault. Empty string is treated as null.
 * - `_limit`: currently ignored — doc_list always returns every
 *   matching doc. The parameter is kept in the ABI for forward-
 *   compatibility; Swift-side slicing enforces pagination today.
 *
 * Returns the `docs` array from `doc_list` as a JSON string. Each
 * entry includes `id`, `title`, `topic`, `created_at`, `updated_at`,
 * `agent_active`, and paths. Caller frees with `tado_string_free`.
 *
 * # Safety
 * `topic_cstr` may be null. If non-null, must be NUL-terminated
 * UTF-8.
 */
char *tado_dome_notes_list(const char *topic_cstr, int _limit);

/**
 * List notes through Dome's scoped knowledge filter.
 */
char *tado_dome_notes_list_scoped(const char *topic_cstr,
                                  int _limit,
                                  const char *knowledge_scope_cstr,
                                  const char *project_id_cstr,
                                  bool include_global);

/**
 * Create a topic directory explicitly.
 *
 * Returns `{"topic":"<slug>","created":true}` on success.
 */
char *tado_dome_topic_create(const char *topic_cstr);

/**
 * Hard-delete a note document.
 */
char *tado_dome_note_delete(const char *id_cstr);

/**
 * Fetch a single note with both user + agent content inlined.
 *
 * Params:
 * - `id_cstr`: note uuid (from `tado_dome_notes_list`).
 *
 * Returns the `doc_get` payload as a JSON string — `id`, `title`,
 * `topic`, `user_content`, `agent_content`, `updated_at`, etc.
 * Caller frees with `tado_string_free`.
 *
 * # Safety
 * `id_cstr` must be NUL-terminated UTF-8.
 */
char *tado_dome_note_get(const char *id_cstr);

/**
 * Return a graph snapshot for the Knowledge → Graph surface.
 *
 * All pointer arguments are optional except `include_types_json_cstr`,
 * which may also be null. `include_types_json_cstr` must be a JSON
 * array of node kind strings when present.
 */
char *tado_dome_graph_snapshot(const char *focus_node_id_cstr,
                               const char *include_types_json_cstr,
                               const char *search_cstr,
                               int max_nodes);

/**
 * Return a scoped graph snapshot for the Knowledge → Graph surface.
 */
char *tado_dome_graph_snapshot_scoped(const char *focus_node_id_cstr,
                                      const char *include_types_json_cstr,
                                      const char *search_cstr,
                                      int max_nodes,
                                      const char *knowledge_scope_cstr,
                                      const char *project_id_cstr,
                                      bool include_global);

/**
 * Force-refresh the graph projection.
 */
int tado_dome_graph_refresh(void);

/**
 * Fetch a graph node inspector payload by node id.
 */
char *tado_dome_graph_node_get(const char *node_id_cstr);

/**
 * Fetch Claude-agent operational status for Knowledge → System.
 */
char *tado_dome_agent_status(int limit);

/**
 * Fetch recent `retrieval_log` rows for the Knowledge → System
 * surface. Optional filters: `project_id_cstr` (null = all projects),
 * `tool_cstr` (null = all tools, e.g. "dome_search"). Returns the
 * JSON envelope `{ rows, n, consumption_rate, mean_latency_ms }`.
 * Caller frees with `tado_string_free`.
 */
char *tado_dome_retrieval_log_recent(int limit, const char *project_id_cstr, const char *tool_cstr);

/**
 * Phase 3 — supersede `old_id` with `new_id`. UI-side actor. Returns
 * the JSON envelope `{ old_id, new_id, reason }` on success, null on
 * error. Caller frees with `tado_string_free`.
 */
char *tado_dome_node_supersede(const char *old_id_cstr,
                               const char *new_id_cstr,
                               const char *reason_cstr);

/**
 * Phase 3 — confirm or dispute a graph_node. `verdict` must be
 * `'confirmed'` or `'disputed'`. Caller frees with `tado_string_free`.
 */
char *tado_dome_node_verify(const char *node_id_cstr,
                            const char *verdict_cstr,
                            const char *agent_id_cstr,
                            const char *reason_cstr);

/**
 * Phase 3 — soft-archive a graph_node. Caller frees with
 * `tado_string_free`.
 */
char *tado_dome_node_decay(const char *node_id_cstr, const char *reason_cstr);

/**
 * Phase 5 — seed the three default retrieval recipes
 * (architecture-review, completion-claim, team-handoff) at global
 * scope. Idempotent — re-running upserts the latest baked
 * templates without disturbing user-edited project overrides.
 * Returns the count of recipes seeded as a JSON int, or null on
 * daemon failure. Caller frees with `tado_string_free`.
 */
char *tado_dome_recipe_seed_defaults(void);

/**
 * v0.11 — list every retrieval recipe in the given scope. Pass
 * `scope_cstr = "global"` to see only baked defaults, `"project"`
 * to see only project-scoped overrides for the supplied
 * `project_id_cstr`. NULL `scope_cstr` means "all".
 *
 * Returns JSON `{"recipes": [{recipe_id, intent_key, scope,
 * project_id, title, description, template_path, policy, enabled,
 * last_verified_at, ...}]}` or null on failure. Caller frees with
 * `tado_string_free`.
 */
char *tado_dome_recipe_list(const char *scope_cstr,
                            const char *project_id_cstr);

/**
 * v0.11 — apply a recipe and return its `GovernedAnswer`.
 * `intent_key_cstr` must match a recipe row (e.g.
 * `"architecture-review"`). `project_id_cstr` may be null for
 * global scope.
 */
char *tado_dome_recipe_apply(const char *intent_key_cstr,
                             const char *project_id_cstr);

/* ── v0.11 — automation surface ───────────────────────────────── */

/**
 * List every automation. `enabled_filter`: 1 = only enabled, 0 =
 * only paused, anything else = both. `executor_kind_cstr` may be
 * null. `limit` clamped 1..500.
 */
char *tado_dome_automation_list(int enabled_filter,
                                const char *executor_kind_cstr,
                                int limit);

/** Fetch one automation by id. Returns null when missing. */
char *tado_dome_automation_get(const char *id_cstr);

/** Create an automation. `json_input_cstr` is a JSON object body. */
char *tado_dome_automation_create(const char *json_input_cstr);

/** Update an automation. `json_patch_cstr` is a partial JSON object. */
char *tado_dome_automation_update(const char *id_cstr,
                                  const char *json_patch_cstr);

/**
 * Delete an automation. Errors with Conflict if the automation has
 * an active occurrence — Swift should surface and suggest pausing.
 */
char *tado_dome_automation_delete(const char *id_cstr);

/**
 * Toggle paused state. `paused != 0` calls `automation_pause`,
 * `paused == 0` calls `automation_resume`.
 */
char *tado_dome_automation_set_paused(const char *id_cstr, int paused);

/** Manually enqueue a "right now" occurrence (the Run-now button). */
char *tado_dome_automation_run_now(const char *id_cstr);

/**
 * List occurrences. `automation_id_cstr` null = global ledger.
 * `status_cstr` filters by status string. `from_cstr` and
 * `to_iso_cstr` are optional RFC3339 timestamps.
 */
char *tado_dome_automation_occurrence_list(const char *automation_id_cstr,
                                           const char *status_cstr,
                                           const char *from_cstr,
                                           const char *to_iso_cstr,
                                           int limit);

/** Retry a failed/cancelled occurrence. */
char *tado_dome_automation_retry_occurrence(const char *occurrence_id_cstr);

/* ── v0.12 — system observability + audit + eval ─────────────────── */

/** Vault health checks (existence, sqlite open, audit log, …). */
char *tado_dome_system_health(void);

/** Scheduler queue depths + stale leases + worker cursors. */
char *tado_dome_system_automation_status(void);

/* tado_dome_system_runtime_envelope removed in v0.16.1 — was added
 * in v0.12 but never gained a Swift caller. The health + scheduler
 * cards already cover what operators need. */

/**
 * Tail the audit log. `since_cstr` may be null. `limit` clamped 1..1000.
 * Returns JSON `{entries: [...]}`.
 */
char *tado_dome_audit_tail(const char *since_cstr, int limit);

/**
 * In-process `dome-eval replay`. `vault_db_cstr` is the absolute
 * path to `<vault>/.bt/index.sqlite`. `since_seconds <= 0` →
 * every row. Returns JSON-serialized `ReplayReport`.
 */
char *tado_dome_eval_replay(const char *vault_db_cstr, long long since_seconds);

/* ── v0.13 — bulk import + vault status + tokens ─────────────────── */

/** Vault status snapshot — paths + doc count + topics count. */
char *tado_dome_vault_status(void);

/**
 * Walk `root_path_cstr` (must be inside the vault; null = entire
 * vault root) and return importable items. Used by the Knowledge
 * → Imports wizard step 1.
 */
char *tado_dome_import_preview(const char *root_path_cstr);

/**
 * Execute the import. `items_json_cstr` is a JSON array of the
 * `import_preview.items` shape — pass back whatever subset the
 * user confirmed. Returns JSON `{imported, failures, count}`.
 */
char *tado_dome_import_execute(const char *items_json_cstr);

/** List every issued agent token (revoked ones included). */
char *tado_dome_token_list(void);

/**
 * Issue a token. `caps_csv_cstr` is a comma-separated list of
 * capabilities. Returns JSON `{token, token_id, agent_name,
 * caps}` — the `token` field is the one-time secret.
 */
char *tado_dome_token_create(const char *agent_name_cstr,
                             const char *caps_csv_cstr);

/** Rotate a token's secret. Old secret stops working immediately. */
char *tado_dome_token_rotate(const char *token_id_cstr);

/** Revoke a token. Authentication fails afterward. */
char *tado_dome_token_revoke(const char *token_id_cstr);

/* ── v0.14 — calendar daemon mode + topic browser + graph + packs ──── */

/**
 * Daemon-backed calendar feed. Returns the bt-core
 * `calendar_range` envelope. `from_cstr`, `to_iso_cstr`,
 * `timezone_cstr` non-null. `agent_cstr` and `status_cstr` may be
 * null.
 */
char *tado_dome_calendar_range(const char *from_cstr,
                               const char *to_iso_cstr,
                               const char *timezone_cstr,
                               const char *agent_cstr,
                               const char *status_cstr);

/** List every topic dir under `<vault>/topics/`. */
char *tado_dome_topic_list(void);

/** All graph edges touching a single doc. */
char *tado_dome_graph_links(const char *doc_id_cstr);

/**
 * List context packs. All filter args optional. `limit` clamped
 * 1..500.
 */
char *tado_dome_context_list(const char *brand_cstr,
                             const char *session_id_cstr,
                             const char *doc_id_cstr,
                             int limit);

/** Fetch one context pack by id with manifest + summary + sources. */
char *tado_dome_context_get(const char *context_id_cstr);

/* ── v0.15 — suggestions surface ──────────────────────────────── */

/** List suggestions. Both filters optional. */
char *tado_dome_suggestion_list(const char *doc_id_cstr,
                                const char *status_cstr);

/** Accept a pending suggestion (applies patch). */
char *tado_dome_suggestion_apply(const char *id_cstr);

/**
 * Phase 4 — compose the spawn-time preamble in Rust. Byte-equivalent
 * to `Sources/Tado/Extensions/Dome/DomeContextPreamble.swift`'s
 * `build(for:)` once the Swift composer adopts the deterministic
 * relative-time formatter. JSON request body shape:
 *
 * ```json
 * {
 *   "agent_name":   "backend",
 *   "project_name": "Tado",
 *   "project_id":   "11111111-…",
 *   "project_root": "/Users/miguel/Documents/tado",
 *   "team_name":    "core",
 *   "teammates":    ["frontend"]
 * }
 * ```
 *
 * Returns the rendered preamble as a heap-allocated UTF-8 string, or
 * null when there's nothing to render. Caller frees with
 * `tado_string_free`.
 */
char *tado_dome_compose_spawn_preamble(const char *json_args_cstr);

/**
 * Phase 3 — read enrichment queue depth for the Knowledge → System
 * backfill chip. Returns `{ queued, running, done, failed }` JSON.
 */
char *tado_dome_enrichment_queue_depth(void);

/**
 * Fetch scoped Claude-agent operational status for Knowledge → System.
 */
char *tado_dome_agent_status_scoped(int limit,
                                    const char *knowledge_scope_cstr,
                                    const char *project_id_cstr,
                                    bool include_global);

/**
 * Resolve the latest context pack for a brand/session/doc tuple.
 * Wraps `service.context_resolve(...)`. Returns the JSON envelope
 * bt-core produces, or null on daemon-down / failure. Caller frees
 * with `tado_string_free`.
 *
 * All pointers are optional. At least one of `brand_cstr` or
 * `session_id_cstr`/`doc_id_cstr` will typically be set; passing all
 * nil returns whatever pack the brand-default lookup finds.
 */
char *tado_dome_context_resolve(const char *brand_cstr,
                                const char *session_id_cstr,
                                const char *doc_id_cstr,
                                const char *mode_cstr);

/**
 * Compact a brand/session/doc context pack via
 * `service.context_compact(...)`. Caller passes `force=true` to
 * rebuild even if the source hash hasn't changed. Returns the
 * produced manifest JSON or null on failure. Caller frees with
 * `tado_string_free`.
 */
char *tado_dome_context_compact(const char *brand_cstr,
                                const char *session_id_cstr,
                                const char *doc_id_cstr,
                                bool force);

/**
 * Install the Tado-owned Claude status line script into the Dome vault.
 *
 * This does not mutate Claude settings by itself. Swift can decide how
 * aggressively to register the returned script path in user settings.
 */
char *tado_dome_install_status_line_script(const char *vault_cstr);

/**
 * Trigger `vault.reindex` — re-runs every doc through the live
 * embedder, upgrading legacy `noop@1` chunks to the current Qwen3
 * model. Long-running (30-60s on 1000 notes); Swift dispatches via
 * `Task.detached` to keep the UI responsive.
 *
 * Returns `{"ok": true}` on success or null on failure. Caller frees
 * via `tado_string_free`.
 */
char *tado_dome_vault_reindex(void);

/**
 * Snapshot of `note_chunks` rows grouped by embedding model. Used by
 * the Knowledge → Agent System "Embeddings" panel to show how many
 * chunks are still on legacy embeddings.
 *
 * Returns JSON `{"model_counts": { "<id>@<version>": <count>, ... },
 * "total": <count>}` or null on failure.
 */
char *tado_dome_vault_embedding_stats(void);

/**
 * Recursively ingest a directory as Dome notes. One note per
 * eligible file, capped at 5000 (`capped: true` in the result if hit).
 *
 * Returns JSON `{"created": N, "skipped": M, "capped": <bool>}` or
 * null on failure.
 *
 * # Safety
 * `path_cstr` must be a NUL-terminated UTF-8 string. The optional
 * pointers (`topic`, `project_id`, `project_root`) may be null.
 */
char *tado_dome_vault_ingest_path(const char *path_cstr,
                                  const char *topic_cstr,
                                  const char *owner_scope_cstr,
                                  const char *project_id_cstr,
                                  const char *project_root_cstr);

/**
 * Read-only count of docs that `tado_dome_vault_purge_topic_scope`
 * would delete. Used by the Swift confirmation dialog so the operator
 * sees the exact number before confirming. Returns JSON
 * `{"count": N, "topic": ..., "owner_scope": ..., "project_id": ...}`
 * or null on failure.
 *
 * # Safety
 * `topic_cstr` and `owner_scope_cstr` must be NUL-terminated UTF-8.
 * `project_id_cstr` may be null (matches docs.project_id IS NULL).
 */
char *tado_dome_vault_purge_topic_scope_count(const char *topic_cstr,
                                              const char *owner_scope_cstr,
                                              const char *project_id_cstr);

/**
 * Bulk-delete every doc matching `(topic, owner_scope, project_id?)`
 * along with cascade rows (`note_chunks`, `doc_meta`, `fts_notes`,
 * `graph_nodes`, `graph_edges`) and the on-disk `topics/<topic>/<slug>/`
 * folders. Used by the Knowledge → Agent System "Clear globally-
 * ingested codebases" button to undo a misclicked global ingestion in
 * one shot.
 *
 * `project_id_cstr` may be null — that matches `docs.project_id IS NULL`
 * (every owner_scope='global' row stores NULL there).
 *
 * Returns JSON `{"purged": N, "topic": ..., "owner_scope": ...,
 * "project_id": ...}` or null on failure.
 */
char *tado_dome_vault_purge_topic_scope(const char *topic_cstr,
                                        const char *owner_scope_cstr,
                                        const char *project_id_cstr);

/**
 * Live snapshot of legacy `vault_ingest_path` progress. Caller frees
 * the returned C string with `tado_string_free`. Always returns a
 * JSON object — null only if the daemon hasn't booted.
 *
 * JSON shape: `{ running, created, skipped, total, canceled }`.
 */
char *tado_dome_vault_ingest_progress(void);

/**
 * Request that the in-flight ingest stop at the next file boundary.
 * Returns 1 if an ingest was running, 0 otherwise. Idempotent.
 */
int tado_dome_vault_ingest_cancel(void);

/**
 * Register a project for code indexing. Idempotent.
 *
 * Returns JSON `{ ok, project_id, name, root_path, enabled }` or
 * null on failure. Caller frees with `tado_string_free`.
 *
 * # Safety
 * All pointers must be NUL-terminated UTF-8.
 */
char *tado_dome_code_register_project(const char *project_id_cstr,
                                      const char *name_cstr,
                                      const char *root_path_cstr,
                                      bool enabled);

/**
 * Unregister a project from code indexing. With `purge=true`,
 * deletes every chunk row for the project too.
 */
char *tado_dome_code_unregister_project(const char *project_id_cstr, bool purge);

/**
 * List every registered code project plus per-project file/chunk
 * counts. Used by Settings → Code Indexing.
 */
char *tado_dome_code_list_projects(void);

/**
 * Run a full code index. Blocks for the duration of the walk +
 * embed (minutes for a multi-thousand-file project). Swift MUST
 * invoke from `Task.detached`.
 *
 * Returns the `IndexResult` JSON on success or null on failure.
 */
char *tado_dome_code_index_project(const char *project_id_cstr, bool full_rebuild);

/**
 * Start a file watcher for a registered project. Idempotent — a
 * second call replaces the existing watcher for the same project.
 * The watcher debounces 500 ms and incrementally re-embeds changed
 * files via the same `replace_chunks_for_file` path the full
 * indexer uses.
 */
char *tado_dome_code_watch_start(const char *project_id_cstr);

/**
 * Stop the file watcher for a project. No-op if no watcher was
 * running. Returns `{ ok, project_id, watching: false, had_watcher }`.
 */
char *tado_dome_code_watch_stop(const char *project_id_cstr);

/**
 * List every project_id with an active watcher.
 */
char *tado_dome_code_watch_list(void);

/**
 * Reattach watchers for every `enabled=1` project. Called on app
 * boot from `tado_dome_start` and on `AppSettings.codeIndexingEnabled`
 * flipping back to `true` from Swift. Idempotent — projects that
 * already have a watcher are skipped.
 */
char *tado_dome_code_watch_resume_all(void);

/**
 * Stop every active watcher in one call. Used when the per-user
 * kill switch flips off or before vault relocation.
 */
char *tado_dome_code_watch_stop_all(void);

/**
 * Hybrid search across the indexed code chunks.
 *
 * Accepts a JSON envelope so the FFI signature stays stable as we
 * add more knobs (project filter, language filter, alpha):
 *
 * ```json
 * {
 *   "query": "where do we spawn the PTY",
 *   "project_ids": ["tado"],
 *   "languages": ["rust", "swift"],
 *   "limit": 25,
 *   "alpha": 0.6
 * }
 * ```
 *
 * Returns the bt-core `code.search` payload as JSON, or null on
 * failure. Caller frees with `tado_string_free`.
 */
char *tado_dome_code_search(const char *query_json_cstr);

/**
 * Read the live progress snapshot for an in-flight index. Cheap;
 * safe to poll from the main thread every 250 ms.
 */
char *tado_dome_code_index_status(const char *project_id_cstr);

#endif  /* TADO_CORE_H */
