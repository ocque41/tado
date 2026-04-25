# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-04-25

The longest single release in Tado's history. v0.9.0 bundles five months
of foundation-v2 work into one ship: the Cargo workspace, the
extension host, the in-process Dome second brain, the real-time A2A
event socket, the Rust port of `tado-mcp`, scoped knowledge with
Qwen3-Embedding-0.6B, and the relocatable storage root. Every layer of
the app changed. The Rust workspace grew from one crate to eight.
Notifications, Dome, and the new Cross-Run Browser moved out of
modal sheets into a dedicated extension host. Agents launched inside
Tado tiles now share a vector-indexed markdown knowledge vault and a
real-time event socket, so they can react to each other in
milliseconds instead of polling the file system. The bundled `.app`
ships zero Node runtimes — every MCP server is a Rust `[[bin]]`.

If you're upgrading directly from v0.8.0, every section below applies.
v0.10.0–v0.13.0 prereleases that previewed slices of this work are
folded in here (their tags have been removed); the **Migration notes**
section at the bottom calls out the parts you may need to manually
reconcile.

### Added — Foundation: Cargo workspace + Rust everywhere

- **Cargo workspace under `tado-core/`** — the single-crate Rust core
  promotes to a workspace with eight members: `crates/tado-terminal`
  (the existing PTY + grid + VT parser, unchanged), `crates/tado-shared`
  (placeholder for future cross-crate primitives), `crates/tado-ipc`
  (Rust contract types matching `IPCMessage.swift` byte-for-byte),
  `crates/tado-settings` (atomic JSON IO + the five-scope enum +
  canonical Application Support / per-project path helpers),
  `crates/bt-core` (the trusted-mutator notes/automation/JSON-RPC
  crate from Dome — see Dome section), `crates/dome-mcp` and
  `crates/tado-mcp` (the two stdio MCP bridges), and `crates/tado-dome`
  (the new scoped-knowledge CLI). Every member links into the same
  `libtado_core.a` Package.swift already consumes — no link-path
  changes anywhere.
- **`tado-ipc` Rust crate** — `IpcMessage`, `IpcMessageStatus`,
  `IpcSessionEntry` mirror the Swift shapes (camelCase preserved via
  serde rename); `IpcPaths` derives the canonical `/tmp/tado-ipc`
  layout (`registry.json`, `a2a-inbox`, `sessions/<id>/{inbox,outbox,log}`);
  `write_external_message` does atomic temp+sync+rename so the broker
  never sees a half-flushed envelope. Ten tests cover the
  byte-compatible shapes plus the success / inbox-missing failure
  paths.
- **`tado-settings` Rust crate** — `Scope` enum
  (Runtime > ProjectLocal > ProjectShared > UserGlobal > BuiltInDefault)
  with `precedence()` + `is_persisted()`. `read_json` returns `None`
  for missing files (so scope-merge callers can fall through).
  `write_json` does serialize-to-bytes-first, `.{name}.tmp`-in-same-dir,
  fsync, then rename — no half-written file ever visible.
  `SettingsPaths` centralizes the `~/Library/Application Support/Tado/`
  + `<project>/.tado/` paths Swift's `StorePaths` used to hardcode in
  multiple places, and now resolves through the new
  `StorageLocationManager` (see Storage section). Thirteen tests cover
  precedence, atomic-IO discipline, missing files, and path
  composition.
- **Sibling-FFI bridge in `tado-terminal`** — `sibling_ffi.rs`
  re-exports symbols inside `libtado_core.a` so Swift can reach every
  workspace crate without a separate static lib:
  `tado_ipc_send_external_message`, `tado_ipc_read_registry_json`,
  `tado_ipc_write_registry_json`, `tado_settings_write_json`,
  `tado_settings_read_json`. Strings flow back through the existing
  `tado_string_free` so there's one allocator boundary, not two.
- **Registry serialization ported to Rust** — `registry.json` reads
  and writes now live in `tado-core/crates/tado-ipc/src/registry.rs`.
  Swift's `IPCBroker.updateRegistry` routes through the
  `tado_ipc_write_registry_json` FFI that validates the payload via
  `serde_json::Deserialize`, re-emits it in the exact byte layout
  Swift's `JSONEncoder([.prettyPrinted, .sortedKeys])` produced
  (2-space indent, `" : "` separator, sorted keys, atomic
  tmp+rename), and falls back to the legacy Swift writer on any FFI
  error so CLIs can't observe a stale file.
  `IpcSessionEntry.{projectName, agentName, teamName, teamID}`
  serialize with `skip_serializing_if = "Option::is_none"` instead
  of explicit `null`, matching Swift's "omit nil optionals" default —
  Rust-written and Swift-written registries are byte-identical for
  the common case.
- **`tado-mcp` is now Rust** — the last JavaScript surface in the
  Tado runtime moves into `tado-core/crates/tado-mcp/`. All 12 tools
  from the old Node server (`tado_list`, `tado_send`, `tado_read`,
  `tado_broadcast`, `tado_notify`, `tado_events_query`,
  `tado_config_{get,set,list}`, `tado_memory_{read,append,search}`)
  are implemented with matching schemas, target-resolution rules
  (UUID / grid coordinates / name substring), and output formatting.
  File layout, atomic-write discipline, and the ANSI-stripping regex
  in `tado_read` are byte-identical to the Node tree. Ships as a
  `[[bin]]` alongside `dome-mcp` so the bundled `.app` no longer
  depends on a Node runtime on the user's machine.
- **Swift auto-register for tado-mcp** — `TadoApp.init` kicks off a
  detached task that (a) skips cleanly if `claude` CLI isn't on
  PATH, (b) greps `claude mcp list` for an existing `tado` entry,
  (c) otherwise runs `claude mcp remove tado --scope user || true` +
  `claude mcp add tado --scope user -- <bundled>/tado-mcp`. Stale
  Node registrations are automatically replaced on next launch;
  manual intervention is never required.
- **`make mcp` builds both bridges** — invokes
  `cargo build --release -p dome-mcp -p tado-mcp` so iterating on
  either MCP server rebuilds both binaries in the release profile
  the app-bundle packager expects.

### Added — Extension host

- **Extension host in Swift** —
  `Sources/Tado/Extensions/AppExtensionProtocol.swift` defines the
  `AppExtension` protocol + Codable `ExtensionManifest` (id /
  displayName / shortDescription / iconSystemName / version /
  defaultWindowSize / windowResizable). `ExtensionRegistry.all` is
  the compile-time source of truth for bundled extensions;
  `runOnAppLaunchHooks` fans out one-time setup concurrently.
- **Extensions page** — the top nav gains an "Extensions" tab
  rendering `ExtensionRegistry.all` as a branded grid of cards.
  Clicking a card opens the extension's own window via
  `@Environment(\.openWindow)`. Future entries drop in behind one
  `ExtensionRegistry.all` edit plus one matching `WindowGroup`
  scene in `TadoApp.body` — no dynamic loading; everything is
  compile-time.
- **Notifications extension** — the bell icon in the sidebar now
  calls `openWindow(id: "ext-notifications")` instead of toggling a
  sheet, opening a peer window that lets the user keep watching
  agents while scrolling event history. Same `EventBus.shared.recent`
  data source, same severity-chip + free-text filter bar, same
  context menu (copy title, copy event JSON), same "Mark all read"
  + dock badge refresh. Keyboard `Cmd-W` / red close-box dismiss
  it natively.
- **Cross-Run Browser extension** — one pane aggregates every
  `EternalRun` + `DispatchRun` across every project into a
  reverse-chronological timeline, so "what am I running?" no longer
  requires a tour through individual project detail pages. Sidebar
  picker (All / Eternal / Dispatch) + Active-only toggle +
  full-text filter over labels and project names. Each row shows
  the run label, state chip, project name, and (for eternal runs)
  the live sprint count and last metric read from `state.json`. A
  "Reveal in Finder" action opens the on-disk artifact directory.
  Read-only — edits still flow through the canonical project-detail
  surfaces.

### Added — Dome: in-process knowledge with project scoping

- **Dome second brain runs in-process** — Tado boots a vector-indexed
  markdown knowledge store alongside the canvas in a single `.app`.
  At app launch `DomeExtension.onAppLaunch()` fires via
  `ExtensionRegistry.runOnAppLaunchHooks()`; the FFI entry
  `tado_dome_start()` spawns a dedicated 2-worker Tokio runtime,
  opens a vault at `~/Library/Application Support/Tado/dome/`, runs
  bt-core's 21 migrations, and binds a Unix socket at
  `<vault>/.bt/bt-core.sock`. Every Claude Code agent launched
  inside a Tado terminal can reach the daemon through the bundled
  `dome-mcp` stdio bridge. One process in Activity Monitor; one
  `.app` to ship.
- **bt-core crate in the workspace** — the trusted-mutator crate
  from Dome (atomic writes + write barrier + markdown notes store
  + FTS5 + vector-search + automation scheduler + JSON-RPC) lives
  in `tado-core/crates/bt-core` (~25 KLOC). Compiles as a workspace
  member; its C-ABI surface re-exports through `tado-terminal` into
  `libtado_core.a`. `#![allow(dead_code)]` at `service.rs` top
  silences warnings against ~3000 LOC of craftship/openclaw/
  runtime-branding scaffolding still reachable from RPC handlers
  kept alive for migration compatibility.
- **dome-mcp stdio bridge bundled** — a `[[bin]]` target builds a
  release binary that Claude Code spawns per-agent via
  `claude mcp add dome …`. Exposes eight tools: the original four
  (`dome_search`, `dome_read`, `dome_note`, `dome_schedule`) plus
  four new ones for the Claude agent contract:
  `dome_graph_query`, `dome_context_resolve`, `dome_context_compact`,
  and `dome_agent_status` — agents must use these before making
  stale architecture or completion claims.
- **Dome FFI symbols** — `tado_dome_start(vault_cstr)`,
  `tado_dome_stop()`, `tado_dome_note_write(scope, topic, title,
  body)`, the new `tado_dome_note_write_scoped(...)` for
  project-scoped knowledge with explicit `owner_scope`, `project_id`,
  `project_root`, `knowledge_kind` parameters,
  `tado_dome_notes_list(topic, limit)`, `tado_dome_note_get(id)`,
  `tado_dome_issue_token`, plus graph and context-resolution FFIs.
  cbindgen emits them into `tado_core.h`; the Makefile
  `sync-header` target keeps `Sources/CTadoCore/include/tado_core.h`
  in lock-step on every `dev`/`debug`/`build` so forgetting the
  copy is no longer possible.
- **Four working Dome surfaces** — `DomeRootView` is a 4-tab shell
  cycling between User Notes, Agent Notes, Calendar, and Knowledge,
  with a live daemon-status footer tinted green/red/warning by the
  most recent `dome.*` event. Every surface uses Tado's `Palette` +
  Plus Jakarta Sans. User Notes ships a full HSplitView editor
  (title + TextEditor, ⌘↵ to save, discard/save bar) backed by the
  scoped `tado_dome_note_write_scoped` FFI. Agent Notes is
  read-biased (bt-core's write barrier prevents UI writes to
  `agent.md` regardless). Calendar groups `EventBus.shared.recent`
  by day in reverse-chronological order with severity-tinted dots.
  Knowledge is a three-page surface (List / Graph / System) over
  every note in the vault.
- **DomeRpcClient — typed Swift binding to bt-core** — replaces the
  ad-hoc JSON-RPC payload building the desktop shell used to do.
  Exposes Codable `NoteSummary`, `Note`, `GraphNode`, `GraphEdge`,
  `GraphLayoutPoint`, `GraphLayoutCluster`, scope-resolution helpers,
  and project/global selection state. Dome surfaces program against
  these types, so adding a field is one diff in `DomeRpcClient.swift`
  + bt-core, never a hand-built `{"actor": …, "method": …,
  "params": …}` blob in the UI.
- **Dome scope selection — global vs project (with merge)** — every
  Dome surface that reads or writes notes now takes a
  `DomeScopeSelection` (`global` or `project(id, name, rootPath,
  includeGlobal)`). Project scope can opt into reading global
  knowledge alongside its own (`includeGlobal: true`) so an agent
  in a project still sees user-level notes, while writes always
  go to the explicitly-chosen scope. Drives the picker in every
  surface header and the `dome-mcp` argument plumbing for
  `knowledge_scope`/`project_id`/`include_global` defaults.
- **Dome is the project memory** — every new Tado project auto-seeds
  a `project-<shortid>` Dome topic with an overview note (name,
  root, id, created-at). Topic slug format `project-<first-8-hex-of-uuid>`
  stays collision-free and bt-core-safe-segment-compatible. The
  project overview is the backbone for the context preamble and
  the Eternal-retro mirror.
- **Team roster mirrors to Dome** — creating a team in a project's
  detail view now writes a `team-<sanitized-name>` note to the
  project's Dome topic. Note body lists agents + reach-by-CLI hints
  + cross-links the project topic; agents spawned into the team
  can `dome_search --topic project-<id>` to discover who their
  teammates are without rescraping SwiftData.
- **Spawn-time context preamble** — every non-Eternal agent terminal
  launched via the Tado canvas wakes with a markdown block prepended
  to its first prompt. Four fragments compose the preamble:
  **identity** (agent name + definition path), **project** (name /
  root / id / dome-topic), **team** (name + teammates), and
  **recent project notes** (latest 5 from the project's Dome topic).
  Wrapped in `<!-- tado:context:begin -->` markers so the user's
  actual prompt stays distinguishable in every agent transcript.
  Hard-capped at ~6000 characters (≈1500 tokens).
- **Eternal retros mirror to Dome** — `RunEventWatcher` appends a
  structured retro line to the project's Dome topic on every
  sprint-increment and run-completion event. Sprint retros carry
  metric + iterations + last progress note; completion retros add
  the final stats + mode. Same topic the Eternal architect's
  STEP 0.5 query hits, closing the Eternal ↔ Dome context loop.
- **Qwen3-Embedding-0.6B replaces the hash-noop embedder** — the
  embedding abstraction in `bt-core/src/notes/embeddings.rs` now
  exposes `EmbeddingModelMetadata` (model_id, model_version,
  dimension, pooling, instruction, source_hash) per chunk, with
  `DEFAULT_EMBEDDING_DIMENSIONS = 1024` for Qwen3 in production
  alongside the legacy 384-dim `noop@1` rows. New rows record their
  actual model metadata; on read, the search layer normalizes
  vectors so legacy and new chunks cohabit without rebuilding the
  whole corpus.
- **Knowledge graph + context contract** — bt-core grows a graph
  ontology with `context_event` nodes alongside the existing
  document/run/framework/agent kinds. The four new MCP tools
  surface this as a contract Claude agents must use:
  `dome_graph_query` (typed nodes/edges/clusters),
  `dome_context_resolve` (the relevant slice for the active task),
  `dome_context_compact` (drop stale/irrelevant entries), and
  `dome_agent_status` (the agent's own observability record).
  Knowledge surface page 2 ("Graph") visualizes this in the UI.
- **`tado-dome` CLI crate** — a new Rust `[[bin]]` for canvas agents
  that need to register or query scoped Dome knowledge from inside
  a terminal tile. Talks to the in-process bt-core daemon over the
  existing Unix socket; respects the same scope/project semantics
  as the desktop UI.
- **MCP auto-register on first launch** — after `tado_dome_start`
  succeeds, Swift checks `claude --version` availability, greps
  `claude mcp list` for an existing dome entry, and (if absent)
  mints a fresh capability-scoped token via
  `tado_dome_issue_token` + runs
  `claude mcp add dome --scope user -- <bundled-path>/dome-mcp <vault> <token>`
  with shell-escaped args. Idempotent; silent fallback if `claude`
  CLI is missing. Combined with the matching `tado-mcp` register
  flow, the canonical install does not require any manual
  `claude mcp add` invocation.
- **Migration 19 → 21** — schema bumps `LATEST_SCHEMA_VERSION`
  from 18 to 21. Migration 19 added `embedding_model_version` to
  `note_chunks` (forward-compat scaffold). Migration 20 generalizes
  to variable-dimension embeddings (`embedding_model_id`,
  `embedding_dimension`, `embedding_metadata` columns), seeds the
  graph ontology tables for `context_event`, and adds Claude agent
  observability tables. Migration 21 backfills the new columns for
  legacy rows (`noop@1`, dim 384). Existing vaults migrate in
  place on first launch; backups via `BackupManager` are created
  before any destructive change.

### Added — Real-time A2A

- **`/tmp/tado-ipc/events.sock` event fanout** — a Unix-domain
  socket fans every `TadoEvent` to connected subscribers as JSON
  lines. Complements the durable NDJSON log (which stays
  authoritative for history) so agents inside terminal tiles can
  *react* to activity elsewhere within milliseconds instead of
  polling the file. Protocol is line-delimited: send
  `SUBSCRIBE <filter>\n` once after connecting, then read one JSON
  record per matching event. Supported filters: `*` (firehose),
  `topic:<name>` (pub/sub topics), `session:<id>` (events scoped
  to a specific session/run), or any bare prefix on the event
  `kind`. Implementation lives in
  `tado-core/crates/tado-ipc/src/events_socket.rs` using a tokio
  broadcast channel; an end-to-end integration test verifies
  publish-to-subscribe fanout + filter exclusion.
- **`tado-events` CLI** — a new generated CLI script alongside
  `tado-list` / `-send` / `-read` / `-deploy`. Pipe its output
  through `jq`, `grep`, `awk`, etc. for ad-hoc observability.
- **`tado-list --toon` flag** — the most-used generated CLI gains
  an AXI-style compact output. One record per line, space-separated,
  no header: `<grid> <status> <engine> <agent> <project> <team> <sessionID> <name>`.
  Agents using `--toon` burn ~45% fewer tokens parsing `tado-list`
  output than with the default table. Default output is unchanged
  for humans.
- **`SessionStatus.awaitingResponse`** — distinguishes "agent is
  actively asking the user a question / presenting a plan" from
  the lower-urgency "agent is idle at its prompt" (`needsInput`).
  Detected by scraping the bottom of the grid for selector arrows
  (`❯`), `(y/n)` markers, plan-approval language. The new state
  triggers `SystemNotifier` + sound by default so a question on
  any tile reliably gets attention even when the canvas is
  off-screen.

### Added — Storage: relocate Tado outside Application Support

- **`StorageLocationManager` + locator file** — Tado's storage
  root is no longer hardcoded to
  `~/Library/Application Support/Tado/`. A `storage-location.json`
  locator file in the default Application Support root records the
  active root and any pending move; `StorePaths.root` resolves
  through it on every read. Settings → Storage gains
  **Change Location…** (NSOpenPanel for a folder) and
  **Reset to Default** buttons. The selected target is validated
  (cannot be inside the current store, cannot be a file, must be
  writable, must be empty or look like a Tado store). On next
  launch — before SwiftData, file watchers, or Dome open files —
  `StorageLocationManager.applyPendingMoveIfNeeded()` makes a
  pre-move tarball backup, copies the entire store, verifies every
  entry, atomically flips the locator, then prunes the old root.
  Failures are recorded as `lastMoveError` and surfaced in
  Settings without rolling back the user's pre-existing data.
- **Legacy SwiftData store import** — on first launch after upgrade,
  Tado looks for a `default.store` SwiftData file at the
  pre-foundation-v2 path and copies it (plus `-wal` / `-shm`
  siblings) into the new `cache/app-state.store` location. No-op
  if the new path already exists; non-destructive on the legacy
  files.
- **`Tests/TadoCoreTests/StorageAndModelTests.swift`** — XCTests
  cover Codex/Claude model normalization, the locator's
  `activeRoot` override of `StorePaths.root`, and the
  `scheduleMove` → `pendingRoot` write path with
  `TADO_STORAGE_DEFAULT_ROOT` env override.

### Added — Other

- **CLAUDE.md `## Conventions` section** documenting the
  `foundation-v2` rules: Rust-first for new non-UI logic, write
  barrier untouched, no new dispatch safety systems (per the
  existing `feedback_no_dispatch_safety_systems` memory),
  extensions-first for optional features, three-step compile-time
  extension registry workflow.
- **`docs/persistence-and-notifications.md`** updated to cover the
  new storage relocator, scoped knowledge, and the real-time
  events socket.
- **`docs/dome-note-reliability.md`** — design doc covering
  bt-core's write barrier, atomic-write discipline, and the
  scoped-knowledge `note_kind` semantics for agents.
- **`.tado/.gitignore` + `.tado/README.md` + `.tado/config.json`**
  for this repo — Tado dogfoods itself, so its own project state
  is checked in under `commitPolicy: "shared"`. Lock files
  (`*.lock`) are gitignored at the repo root.

### Changed

- **Codex picker default → GPT-5.5**, with normalization for older
  raw values: `gpt-5.1-codex-max`, `gpt-5.1-codex`,
  `gpt-5.1-codex-mini`, `gpt-5.2-codex`, `gpt52Codex`,
  `gpt51CodexMax`, and `gpt51CodexMini` all map to `gpt-5.5`.
  `ClaudeModel.normalizedRawValue` similarly maps legacy camelCase
  IDs (`opus47`, `opus47_1M`, `sonnet46`, `haiku45`) to their
  canonical Anthropic model IDs. Existing `AppSettings` rows
  silently upgrade on next read; users keep their effort/mode
  preferences.
- **`Sources/Tado/Services/IPCBroker.swift`** is no longer the only
  owner of the IPC contract — the Rust `tado-ipc` crate exposes
  the same shapes for non-Swift callers (CLI tools, `tado-dome`,
  future Rust extensions). The Swift broker still owns the runtime
  (file watcher + delivery + shell-script generation).
- **`Makefile`** — new `sync-header` target keeps
  `Sources/CTadoCore/include/tado_core.h` in lock-step with
  cbindgen's output; new `mcp` target builds both stdio bridges.
  `dev`, `debug`, and `build` all depend on `sync-header`.
- **`tado-core/Cargo.toml` workspace members** —
  `crates/{tado-shared,tado-ipc,tado-settings,bt-core,dome-mcp,tado-mcp,tado-dome}`
  added alongside `crates/tado-terminal`. `libtado_core.a` grows
  because every member's symbols ship inside it, but the
  link-path is unchanged.
- **`DomeRootView` rewritten** — the original Phase-2 status card
  is now the 4-tab shell. The status pill moves to the sidebar
  footer; the active tab fills the detail pane.
- **`TadoEvent.domeDaemonStarted(vaultPath:mcpBinaryPath:)`** —
  the success-event body includes the manual `claude mcp add`
  command as a fallback string so users can register the MCP by
  copy-paste even if the auto-register flow fails.
- **`TerminalSession.projectID`** added so spawn-time context
  preamble + scoped Dome notes can resolve to the project's
  identity without scraping SwiftData mid-spawn.

### Removed

- **`AppState.showNotifications`** — replaced by the extension
  window's lifecycle.
- **`Sources/Tado/Views/NotificationsView.swift`** — moved (with
  chrome adjustments) into
  `Sources/Tado/Extensions/Notifications/NotificationsWindowView.swift`.
  ContentView's `.sheet(isPresented: $appState.showNotifications)`
  block deleted.
- **`gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex-mini`** —
  removed from the Codex model picker. Existing settings using
  these IDs auto-migrate to `gpt-5.5` via
  `CodexModel.normalizedRawValue`.
- **Pre-workspace `tado-core/src/`, `tado-core/build.rs`,
  `tado-core/benches/`** — leftover single-crate files that the
  workspace promotion in v0.9.0 made dead. Their content lives in
  `tado-core/crates/tado-terminal/src/` now.

### Fixed

- **Corrupt `refs/tags/v1.0 2.0-rust-metal` zero-hash tag** removed
  from `.git/refs/tags/` — `git show-ref` no longer emits its
  `fatal: bad ref` prelude. The legitimate `v1.0.0-rust-metal`
  historical tag is untouched.

### Migration notes

- **First launch after upgrade is heavier than usual.** Tado has to
  (1) take a tarball backup via `BackupManager`, (2) run bt-core
  migrations 19/20/21 (the embedding metadata + graph ontology +
  agent observability columns), (3) auto-register the `dome` and
  `tado` MCP servers with Claude Code (best-effort, silently
  skipped if `claude` CLI is missing), and (4) bind the Dome Unix
  socket. Expect a few extra seconds of startup; subsequent
  launches are unchanged. `events/current.ndjson` records every
  step.
- **The Dome vault now lives inside Tado's storage root**
  (`<root>/dome/`). If you used Settings → Storage → Change
  Location… to relocate, the vault moves with it on the next
  launch. SQLite WAL files are copied alongside.
- **Legacy 384-dim embeddings (`noop@1`)** stay readable. New
  notes get 1024-dim Qwen3 vectors; mixed-dimension search uses
  per-row metadata to avoid cross-comparison.
- **Pre-existing `claude mcp add` registrations** for `tado` or
  `dome` are replaced on first launch with the bundled Rust
  binaries. If you'd registered `tado-mcp` against a Node copy
  outside the bundle, that registration is removed.

## [0.8.0] - 2026-04-20

### Added

- **Persistence subsystem** -- canonical state moves to on-disk JSON under `~/Library/Application Support/Tado/` (`settings/global.json`, `memory/user.md`, `events/current.ndjson`, `backups/`, `version`) with SwiftData as a rebuildable cache. Per-project state lives under `<project>/.tado/` (`config.json`, `local.json`, `memory/project.md`, `memory/notes/<ISO>-*.md`)
- **Five-scope config hierarchy** (runtime > project-local > project-shared > user-global > built-in default) via `ScopedConfig`. External edits to any JSON file flow back into the app automatically -- `FileWatcher` debounces fs events, re-reads the file, and SwiftUI `@Query` observers redraw
- **Atomic writes + advisory locks** -- every write goes through `AtomicStore` (Swift) or matching bash `flock + tmp + rename` (CLI). Concurrent writes from the app, a terminal, and a hook never tear
- **Migration runner** -- monotonic numbered migrations (`Migration001_CreateGlobalJSON`, `Migration002_CreateProjectJSON`) seed JSON files from existing SwiftData rows on upgrade. Automatic tarball backup pre-apply into `backups/tado-backup-*.tar.gz` via `BackupManager`
- **Event system** -- every state transition (`terminal.completed`, `eternal.phaseCompleted`, `dispatch.runDispatched`, `ipc.messageReceived`, user broadcasts) publishes a typed `TadoEvent` through `EventBus`. Deliverers subscribe independently: `SoundPlayer` (audio), `DockBadgeUpdater` (unread count), `SystemNotifier` (macOS banner), `InAppBannerOverlay` (transient in-app pill), `EventPersister` (append NDJSON, rotate daily)
- **RunEventWatcher** -- diffs `state.json` and `phases/*.json` under each Eternal/Dispatch run dir to emit lifecycle events without polluting the service code
- **Notifications UI** -- bell icon in the sidebar header with unread badge opens a full-history sheet (`NotificationsView`) with severity filter (info/success/warning/error), free-text search, and per-row context menu (copy title, copy JSON)
- **`tado-config` CLI** -- `get`, `set`, `list`, `path`, `export`, `import` across `global` / `project` / `project-local` scopes. Uses the same atomic-store discipline as the Swift app
- **`tado-memory` CLI** -- `read`, `note`, `search`, `path` for user-level and project-level markdown memory
- **`tado-notify` CLI** -- `send "<title>"` publishes a user-visible event; `tail` streams the live event log
- **MCP surface** (`tado-mcp` server) extended with `tado_config_{get,set,list}`, `tado_memory_{read,append,search}`, `tado_notify`, `tado_events_query`. Any MCP-compatible agent can now read/write Tado's settings, append long-lived notes, raise in-app notifications, and query the event history
- **Concurrent runs per project** -- `EternalRun` and `DispatchRun` are SwiftData-modelled so every project can carry multiple megas, sprints, and dispatches in flight simultaneously. UI tracks each run's lifecycle independently; per-run directories (`.tado/eternal/runs/<uuid>/`, `.tado/dispatch/runs/<uuid>/`) isolate state
- **Eternal auto mode** -- Continuous ("internal") Eternal runs now use Claude Code's `--permission-mode auto` (classifier-gated autonomy, Opus 4.7 + Max/Teams/Enterprise plan). Replaces the old `--dangerously-skip-permissions` bypass flow. Tado hard-pins Opus 4.7 for internal runs so a non-Opus default in Settings can't footgun a Continuous sprint
- **Dual-layer auto-mode config injector** -- one-shot agent writes the classifier's trust context into `~/.claude/settings.json` (user scope, affects every Claude Code session on the machine) AND `<project>/.claude/settings.local.json` (gitignored project-local). The committed `<project>/.claude/settings.json` is explicitly left untouched so Tado trust context doesn't leak into teammates' checkouts
- **Per-phase model / effort** -- Eternal architect plans can now specify `model` and `effort` per phase, so cheaper phases run on Haiku 4.5 while heavier phases escalate to Opus 4.7
- **Architect STEP 5.5 self-check** -- coverage audit + stack-drift detection inside the architect's plan-shaping loop. Composite evaluator score on the sprint-2 dogfood run reached 0.938
- **Opus 4.7 1M context variant** -- model picker adds "Opus 4.7 1M" using the bracket-form model id `opus[1m]`. Flags are now shell-escaped at spawn time so the brackets survive zsh's `nomatch` without aborting the spawn
- **Extra high effort** -- `ClaudeEffort.extraHigh` (`--effort xhigh`) exposed in the picker; verified to match Claude Code v2.1.114+ and graceful-fails on older CLI builds
- **Claude mode: Auto mode** -- `ClaudeMode.autoMode` replaces `autoAcceptEdits` to mirror the current Claude Code Mode picker (Shift+⌘+M); picker order tracks Claude's own UI
- **Settings tooltips** -- every picker, toggle, and stepper in `SettingsView` gets an `InfoTip` explaining what the setting does and when to flip it
- **Sidebar redesign** -- sessions grouped by project with collapsible sections, live filter, uptime-per-session via `TimelineView`, Notifications bell with unread badge, consolidated "Terminate all" footer
- **User input cooldown** -- typing into an internal-mode Eternal worker pauses Tado's 5 s idle-injection for 60 s so modal flows (Ctrl+C confirmations, arrow-key navigation inside Claude Code's UI) aren't clobbered by `/loop` prompts landing on top of the dialog
- `docs/persistence-and-notifications.md` -- cold-read reference for the persistence and notifications subsystems

### Changed

- `TadoApp` now owns a single `ModelContainer` in `init()` so migrations, `AppSettingsSync`, `ProjectSettingsSync`, and `@Query` observers all share one store. Startup order: migrations → `ScopedConfig.bootstrap` → sync start → deliverer install → `systemAppLaunched` event
- `ProcessSpawner` shell-escapes every CLI flag before joining (`map(shellEscape).joined`). Load-bearing for `opus[1m]`; harmless for simple tokens
- Internal-mode Eternal worker command accepts `modelID` + `effortLevel` parameters instead of relying on `~/.claude/settings.json` defaults
- FULL AUTO toggle in `EternalFileModal` is now only shown for External loops (it flips `--dangerously-skip-permissions` in `eternal-loop.sh`, which Internal mode doesn't use)
- Run deletion (`EternalService.deleteRun`, `DispatchPlanService.deleteRun`) uses SIGKILL (`hard: true`) on linked sessions, deletes the SwiftData row synchronously, then removes the run directory async with 200 ms + 1 s retry backoff. Fixes "directory couldn't be removed" races where the PTY's log file was still open in the dying process

### Fixed

- Internal-mode Eternal workers no longer silently ignore the user's model/effort picks (the per-turn `claude` invocation now receives explicit `--model` / `--effort` args)
- `--model opus[1m]` no longer aborts with zsh's `nomatch` error before `claude` can parse the flag
- Sessions paused at a Claude Code modal dialog (e.g. Ctrl+C confirmation) no longer receive `/loop` prompts landing on top of the dialog and corrupting state

## [0.7.0] - 2026-04-19

### Added

- **Rust + Metal terminal renderer** -- new `tado-core` Rust static library drives every tile's PTY via `portable-pty`; rendering moved from SwiftTerm's AppKit view to a direct Metal pipeline (`MetalTerminalView`, `MetalTerminalTileView`) with its own glyph atlas, ANSI state machine, and scrollback buffer
- Retina-aware text rendering via `NSFont.monospacedSystemFont` and 2x display-scale atlas
- Wide-character support (CJK, box-drawing double-wide), astral-plane codepoint rasterization, NFC composition for combining-mark sequences
- Color emoji via RGBA glyph atlas, atlas-overflow recovery with 4x capacity bump
- ANSI palette theming (15 curated themes propagated into the Metal renderer)
- Text selection with Cmd+C copy, application cursor mode, bell (audible + visual modes), blinking cursor
- Terminal font size setting, live tile resize, zoom correctness
- Performance benchmarks + `BENCH.md`
- **Dispatch self-improvement loop** -- per-phase retros review each phase's output and feed learnings back into subsequent phases
- **Projects redesign** -- card-based project list, sheet-based New Project flow, identity zone, prominent dispatch card, todos zone with team > agent > todo hierarchy, agents disclosure zone. Original 953-line monolith split into a `Projects/` subtree
- **Teams merged into Projects** -- standalone Teams page removed; team management now lives inside each project

### Changed

- SwiftTerm removed; Metal is the default and only renderer
- Design system refresh: Plus Jakarta Sans everywhere, Ember theme, central `Palette` token set, Jakarta Sans catalog wired through every surface
- Settings backdrop uses a blur, page headers raised to `#2A2A2A`, Ember terminal background dropped to `#0A0A0A`
- `claudeNoFlicker` default flipped to `false` so fresh tiles keep scrollback usable; fullscreen Claude UI is now an opt-in toggle

### Fixed

- Silent MTKView draw early-returns caught and recovered
- Metal text spaced-out-on-2x-displays bug (atlas was at 1x)
- Metal tile stuck on "spawn pending" forever (FFI thread-local error was silently dropped)
- Scrollback freeze on long runs (buffer clamped + scroll-back correctness)

## [0.6.0] - 2026-04-16

### Added

- **Dispatch Architect workflow** -- new "Dispatch" button on each project opens a markdown brief modal; accepting spawns a Dispatch Architect agent that designs a multi-phase plan, creates per-phase skills via `/skill-creator`, writes JSON plan files to `.tado/dispatch/`, and injects "Dispatch System" docs into the project's CLAUDE.md/AGENTS.md
- **Start/Redo dispatch controls** -- once the architect is running, the Dispatch button becomes a Start (play) button (launches phase 1) and a Redo button (re-edit the brief and re-plan)
- **Auto-chained phases** -- each phase prompt contains a `tado-deploy` handoff to the next phase, so the entire plan runs end-to-end after the user clicks Start
- `Project.dispatchMarkdown` and `Project.dispatchState` (idle / drafted / planning / dispatching) persisted via SwiftData
- `DispatchPlanService` -- handles plan reset, phase JSON parsing, architect spawn, and phase 1 launch
- `DispatchFileModal` -- markdown editor for the dispatch brief with replan confirmation
- **Model selection** -- new Settings section with dropdowns for Claude models (Opus 4.6, Opus 4.6 1M, Sonnet 4.6, Haiku 4.5) and Codex models (GPT-5.4, GPT-5.4-Mini, GPT-5.3-Codex, GPT-5.2-Codex, GPT-5.2, GPT-5.1-Codex-Max, GPT-5.1-Codex-Mini)
- Model CLI flags passed through to every spawned agent process
- **Random tile colors** -- new `TerminalTheme` system with 15 curated palettes (Tado Dark, Claude Copper, Claude Ink, Pro, Homebrew, Ocean, Grass, Red Sands, Silver Aerogel, Solarized Dark, Dracula, Nord, Monokai, Tokyo Night, Gruvbox Dark)
- Each new tile picks a random theme (excluding the previous one to avoid back-to-back repeats); toggleable via Settings
- **Harness Display settings** -- Claude Code knobs (`CLAUDE_CODE_NO_FLICKER`, `CLAUDE_CODE_DISABLE_MOUSE`, `CLAUDE_CODE_SCROLL_SPEED` 1-20) and Codex alternate-screen toggle
- `ProcessSpawner.codexEmbedShim()` -- alt-screen and env-inheritance flags refactored into a reusable function so alt-screen becomes a user setting

### Fixed

- **Trackpad scrollback** -- scrolling over a freshly-deployed terminal tile (never clicked) is now routed to the terminal's scrollback buffer instead of being swallowed as a canvas pan. Hit-testing replaces the previous first-responder check, and trackpad pixel deltas are synthesized into line scrolls (SwiftTerm's `scrollWheel` only honors classic mouse-wheel `deltaY`, which trackpads always report as 0).
- `LoggingTerminalView.scrollUpLines()` / `scrollDownLines()` -- new helpers that expose SwiftTerm's protected `scrollUp/scrollDown` to the canvas scroll monitor

## [0.5.0] - 2026-04-14

### Added

- `tado-deploy` command -- agents can programmatically spawn new agent sessions on the Tado canvas from within a terminal
- Smart engine resolution -- `tado-deploy` auto-detects engine from agent source (`.claude/agents/` → claude, `.codex/agents/` → codex)
- SpawnRequest IPC -- new file-based IPC flow (`/tmp/tado-ipc/spawn-requests/`) for inter-agent session creation
- Multiline text input -- TodoListView and ProjectTodoInput now use a growing TextEditor (up to 8 lines)
- Submit shortcut changed from Enter to **Cmd+Enter** (`⌘↩`) so newlines work in the input
- Todo renaming -- right-click context menu with "Rename", "Mark as Done", "Move to Trash"
- `TodoItem.name` property with `displayName` computed fallback to the original text
- Enhanced AGENTS.md with a full "Deploying Agents" section covering syntax, flags, defaults, and example workflows
- Project bootstrap now injects the Deploying Agents documentation into target projects

- Bracketed paste mode -- multi-line messages sent to terminals are wrapped in bracketed paste escape sequences so agents receive them as a single paste rather than character-by-character input
- Scaled send delay -- longer text now gets a proportional delay before Enter (base 50ms + 1ms per 100 bytes, capped at 2s) to prevent dropped characters
- `FlowLayout` -- custom SwiftUI layout that wraps agent pills to multiple lines in the Teams view

### Changed

- ProjectsView input layout -- team/agent pickers moved to a dedicated row above the text editor
- TeamsView agent chips -- redesigned as pill-shaped buttons that wrap across multiple lines via FlowLayout

## [0.4.0] - 2026-04-13

### Added

- Tado MCP Server (`tado-mcp/`) -- TypeScript MCP server exposing A2A tools (`tado_list`, `tado_read`, `tado_send`, `tado_broadcast`) for any MCP-compatible AI agent
- Auto-registration of tado-mcp in `~/.claude.json` on launch
- Pub/sub topics system -- `tado-publish`, `tado-subscribe`, `tado-unsubscribe`, `tado-topics` for topic-based messaging
- Broadcast messaging -- `tado-broadcast` sends to all sessions, filterable by `--project` and `--team`
- Team-aware IPC -- `tado-list` and `tado-send` now support `--project` and `--team` filters
- `tado-team` command to list teammates within a session
- Project bootstrap -- one-click injection of Tado A2A documentation into a project's CLAUDE.md and AGENTS.md
- Team bootstrap -- one-click injection of team structure and coordination rules into project docs
- Inline team creation from the project detail view
- Enhanced AGENTS.md with "Contacting Other Agents", "Team Coordination", and "Responding to Agent Requests" sections
- Rich environment variables for spawned processes: `TADO_PROJECT_NAME`, `TADO_PROJECT_ROOT`, `TADO_TEAM_NAME`, `TADO_TEAM_ID`, `TADO_AGENT_NAME`, `TADO_TEAM_AGENTS`
- Registry now includes `teamName` and `teamID` fields

### Changed

- Default view is now Canvas (previously Todos)

## [0.3.0] - 2026-04-12

### Added

- Projects -- organize todos under a directory with auto-discovered agents
- Teams -- group agents from a project into named teams for coordinated work
- Agent discovery -- scans `.claude/agents/` and `.codex/agents/` for agent definition files
- Project-scoped todo input with agent picker
- Project detail view showing teams, agents, and todos in a tree layout
- Teams view with expandable agent management (add/remove agents per team)
- Page navigation bar replacing the old view mode toggle (Todos, Canvas, Projects, Teams)
- Ctrl+Tab now cycles through all four pages
- Todos can be associated with a project, team, and specific agent
- Per-project working directory passed to spawned agent processes

## [0.2.0] - 2026-04-12

### Added

- Done list (Cmd+D) for completed todos
- Trash list (Cmd+T) for discarded todos
- Resizable terminal tiles with drag handles and live dimension indicator
- Moveable terminal tiles via title bar drag
- Tado A2A (Agent-to-Agent) IPC with `tado-read` command for reading terminal output
- Claude Code permission mode setting (ask, auto-accept edits, plan, bypass)
- Codex approval mode setting (default, full access, custom)
- Claude Code thinking effort setting (low, medium, high, max)
- Codex reasoning effort setting (low, medium, high)
- Mode and effort CLI flags passed through to spawned agent processes

## [0.1.0] - 2026-04-12

### Added

- Todo-driven terminal spawning with Claude Code and Codex engine support
- Pannable/zoomable canvas with draggable terminal tiles
- Prompt queueing with auto-send on agent idle detection
- IPC system for agent-to-agent messaging (tado-send, tado-recv, tado-list)
- External CLI tools for messaging Tado sessions from any terminal
- Forward mode for routing typed input to a specific terminal
- Activity detection via terminal cursor monitoring
- SwiftData persistence for todos and settings
- Session sidebar with live status indicators
- Settings panel with engine selection and grid configuration
- Keyboard shortcuts: Ctrl+Tab (view switch), Cmd+M (settings), Cmd+B (sidebar)
