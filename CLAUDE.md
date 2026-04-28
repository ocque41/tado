# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

This file is the canonical map of Tado at v0.16.1. It is grouped so you can
navigate by purpose rather than by feature: build mechanics first, then the
product surface, then the cross-cutting subsystems (state, knowledge, A2A),
then the operational playbooks (bootstraps, releases, history). When two
sections touch the same code path the more abstract one comes first; jump
to **Key Files** for the quickest "where do I edit?" answer.

## Table of Contents

- [Build & Run](#build--run)
- [What This Is](#what-this-is)
- [Rules (the discrete checklist)](#rules-the-discrete-checklist)
- [Conventions (foundation-v2 and beyond)](#conventions-foundation-v2-and-beyond)
- [Architecture](#architecture)
- [Operations Runbook](#operations-runbook)
- [Persistence (settings / memory / events / Dome vault)](#persistence-settings--memory--events--dome-vault)
- [Memory (vault layout, scope, lifecycle, rerank)](#memory-vault-layout-scope-lifecycle-rerank)
- [Context Lifecycle (full agent journey)](#context-lifecycle-full-agent-journey)
- [Knowledge & Memory (Dome second brain + spawn-time context)](#knowledge--memory-dome-second-brain--spawn-time-context)
- [Tado A2A (CLI + MCP + real-time events)](#tado-a2a-cli--mcp--real-time-events)
- [Bootstrapping a project (the four `Bootstrap …` actions)](#bootstrapping-a-project-the-four-bootstrap--actions)
- [Extensions (Notifications, Dome, Cross-Run Browser)](#extensions-notifications-dome-cross-run-browser)
- [Execution (build matrix, verification, rollback)](#execution-build-matrix-verification-rollback)
- [Key Files](#key-files)
- [Releasing ("release next version")](#releasing-release-next-version)
- [Release history (one line per version)](#release-history-one-line-per-version)

## Rules (the discrete checklist)

The hard rules. Every PR / release must satisfy these. Listed
explicitly because the audit pass that drove v0.11–v0.15 found
backend features sitting orphaned for two releases — the FFI ↔ UI
parity rule (rule 4) is the meta-fix that keeps that from
happening again.

1. **No watchdogs, retries, or timeouts on the dispatch chain.**
   Eternal / Dispatch / agent spawn paths run unchecked. If
   something fails, the failure is visible and audit-logged; you
   diagnose and fix it. Do not paper over flakiness with a retry.
2. **Atomic-store discipline.** Every disk write that lands in
   `<storage-root>` goes through `AtomicStore` (Swift) or
   `tado-settings::write_json` (Rust): temp → fsync → rename, with
   a sidecar `.lock` flock. Never write a settings JSON directly.
3. **Additive migrations only.** New schema versions add columns
   / tables / indexes; they never drop or rename. Migrations are
   idempotent (`IF NOT EXISTS` / guarded ALTERs). Pre-migration
   tarball backup is automatic via `MigrationRunner`.
4. **FFI ↔ UI parity.** Every new RPC method that has user-
   relevant semantics must ship with both an FFI shim
   (`tado_dome_<family>_<verb>`) AND a Swift binding (Codable +
   `DomeRpcClient.<family><Verb>`) AND a surface that calls it,
   in the **same release** that introduces it. PR review checks
   `grep -r tado_dome_<symbol> Sources/Tado/` returns at least
   one hit. The 22-category orphan inventory in v0.10 → v0.15 was
   the consequence of not enforcing this.
5. **Bootstrap prompts updated whenever a new agent-facing tool
   ships.** `bootstrapPrompt`, `bootstrapTeamPrompt`,
   `bootstrapAutoModePrompt`, `bootstrapKnowledgePrompt` in
   `Services/ProcessSpawner.swift` are the four bootstraps. Old
   projects rerun the relevant bootstrap to pick up the new
   prose.
6. **Byte-stable spawn-pack contract.** The
   `<!-- tado:context:begin -->` / `<!-- tado:context:end -->`
   markers and the fragment order between them are public API.
   Both the Swift composer and the Rust `compose_spawn_preamble`
   must produce byte-identical output for the same input. Test:
   `bt-core/tests/spawn_pack_byte_equiv.rs` (4 fixtures).
7. **No new ACLs.** Single-user laptop. Scope filters
   (`owner_scope` + `project_id`) plus the write barrier are
   sufficient. `retrieval_log` audit covers cross-scope visibility
   for the threat model that exists.
8. **Destructive actions need confirmation.** Every UI button
   that deletes / revokes / purges / resets shows an `NSAlert`
   with `alertStyle = .critical` and Cancel as the default
   button. Pattern set by the v0.10 codebase-purge button and
   followed by Phase 1–5 surfaces.
9. **Rust-first for new non-UI logic.** Persistence, IPC, atomic
   IO, settings merging, scheduling, retrieval — Rust in
   `tado-core/`. Swift is views + thin bindings + AppKit glue.
10. **Treat every feature change as a full-system change.** Don't
   stop at the user-visible UI tweak. Trace and update window
   wiring, state, settings precedence, Swift views, Rust services,
   FFI, CRUD paths, filtering, tests. If you add a field, scope,
   toggle, topic, or action, check the whole lifecycle.

## Build & Run

```bash
swift build                                  # Build the Swift app
swift run                                    # Build and run
make dev                                     # Build Rust core (release) + sync header + run Swift app
make mcp                                     # Build dome-mcp + tado-mcp stdio bridges (Rust [[bin]]s)
cargo test -p tado-ipc -p tado-settings      # Rust unit tests for IPC + settings crates
```

The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+)
plus a Cargo workspace under `tado-core/` with nine crates:
`tado-terminal` (PTY + grid + VT parser + cbindgen FFI),
`tado-shared` (cross-crate primitives),
`tado-ipc` (IPC contract types + registry serialization),
`tado-settings` (atomic JSON IO + 5-scope enum + path helpers),
`bt-core` (the trusted-mutator notes/automation/JSON-RPC crate fused from Dome),
`dome-mcp` and `tado-mcp` (the two stdio MCP bridges, both Rust `[[bin]]`s),
`tado-dome` (CLI for canvas agents to register/query scoped Dome knowledge),
and `dome-eval` (Rust [[bin]] + [[lib]] for measurable retrieval evaluation —
`replay`, `corpus run`, `explain` subcommands; the v0.10.0 Phase 2 CI gate).
Every member links into the same `libtado_core.a` Package.swift consumes.

## What This Is

Tado is a macOS SwiftUI app that turns a todo list into a terminal multiplexer
for AI coding agents. Each todo item spawns a terminal running either `claude`
(Claude Code) or `codex` CLI with the todo text as the prompt. Terminals are
displayed as tiles on a pannable/zoomable canvas.

Around that core sits a small platform: a persistence subsystem with atomic
file IO, a typed event bus, a knowledge graph (Dome), a real-time A2A bus
between sibling tiles, and an extension host that adds optional surfaces
(Notifications, Dome, Cross-Run Browser).

## Conventions (foundation-v2 and beyond)

- **Rust-first for new non-UI logic.** When you're adding persistence, IPC,
  atomic file IO, settings merging, scheduling, or anything that's
  fundamentally systems-y — write it in Rust inside the `tado-core/` workspace
  (one of `tado-terminal`, `tado-shared`, `tado-ipc`, `tado-settings`,
  `bt-core`, future crates as they arrive). Swift is for views + thin bindings
  + macOS-specific integrations (NSView bridges, NSPasteboard, SwiftUI
  plumbing, AppKit glue).
- **The write barrier stays.** Every mutation that reaches disk goes through
  the atomic-store discipline (temp + sync + rename). Do not bypass it.
- **No new safety systems around dispatch.** Per the existing feedback rule:
  no watchdogs, auto-retry, or timeouts for the agent-dispatch chain.
  Existing retry policies on long-running automations stay as-is; don't add
  new ones.
- **Extensions-first for optional features.** If a feature is valuable but
  optional (examples: Eternal, Dispatch, Notifications, Dome, Cross-Run
  Browser), ship it as an extension using the `AppExtension` protocol in
  `Sources/Tado/Extensions/`. Core Tado stays "canvas of agent terminals"
  plus the minimum UI shell.
- **Compile-time extension registry.** Adding an extension = (1) new Swift
  type conforming to `AppExtension`, (2) entry in `ExtensionRegistry.all`,
  (3) matching `WindowGroup(id: ExtensionWindowID.string(for:))` block in
  `TadoApp.body`. No dynamic loading for v0.
- **Treat every feature change as a full-system change until proven
  otherwise.** Do not stop at the literal UI tweak the user asked for. When a
  feature already exists, trace and update every affected layer: window
  wiring, state, settings precedence, Swift views, Rust services, FFI,
  create/read/update/delete paths, filtering, and tests. If you add a field,
  scope, toggle, topic, or action, check the whole lifecycle so the feature
  still works end to end after the change.
- **Prefer typed Swift↔Rust bindings over ad-hoc JSON-RPC payloads.** For
  desktop UI bindings, call typed Rust service methods through dedicated FFI
  when possible. Avoid hand-building actor/method JSON at the Swift bridge
  unless the feature truly needs generic RPC. If JSON-RPC is unavoidable,
  support legacy field aliases deliberately and test the full request shape
  end to end.
- **Keep agent-facing prompts current.** The four `Bootstrap …` actions
  produce prose that lands in user projects' `CLAUDE.md` / `AGENTS.md`. When
  you ship a new tool, surface, or convention, refresh the corresponding
  prompt in `Services/ProcessSpawner.swift` (`bootstrapPrompt`,
  `bootstrapTeamPrompt`, `bootstrapAutoModePrompt`,
  `bootstrapKnowledgePrompt`) so freshly-bootstrapped projects see the
  current shape, not a v0.4.0-era snapshot.

## Architecture

**State flow:** `TadoApp` creates `@Observable` singletons — `AppState`
(UI state) and `TerminalManager` (session lifecycle) — injected via
SwiftUI `.environment()`. SwiftData persists `TodoItem`, `AppSettings`,
`Project`, `Team`, `EternalRun`, `DispatchRun`, etc., as a rebuildable
cache; the canonical state lives as JSON files on disk (see Persistence).

**Two views, always alive:** `ContentView` keeps both `TodoListView` and
`CanvasView` mounted simultaneously, toggling via opacity. This prevents
terminal processes from being destroyed when switching views. `Ctrl+Tab`
switches between them.

**Todo submission flow:** User types text in `TodoListView` → `TodoItem`
created (SwiftData) → `TerminalManager.spawnSession()` creates a
`TerminalSession` → `MetalTerminalTileView` mounts the Metal tile and
prepends the Dome context preamble to the prompt → `ProcessSpawner`
builds the shell command (`/bin/zsh -l -c "claude 'todo text'"` with
shell-escaped flags including `--model` / `--effort`) → Rust
`tado-terminal` spawns the PTY via `portable-pty`, parses VT sequences in
`performer.rs`, and snapshots the cell grid for the renderer to draw.

**Metal renderer:** The terminal view is a Metal pipeline
(`MetalTerminalRenderer` + `GlyphAtlas` + `Shaders.metal`). SwiftTerm was
removed in v0.7.0; every tile uses the Rust+Metal stack. Wide-char
support, color-emoji RGBA atlas, retina-aware text, ANSI palette theming
(15 curated themes), live tile resize, scrollback clamp.

**Terminal activity detection:** A repeating `Timer` monitors cursor
position. If the cursor hasn't moved for 5 seconds, the session
transitions to `.needsInput`. If the bottom of the grid contains
selector arrows (`❯`), `(y/n)` markers, or plan-approval prompts the
session transitions to `.awaitingResponse` instead — higher urgency,
fires `SystemNotifier` + sound by default.

**Forward mode:** Clicking the arrow button on a todo row sets
`appState.forwardTargetTodoID`. The next text submission goes to that
terminal's session via `enqueueOrSend()` instead of creating a new
todo. One-shot: forwarding deactivates after one message.

**Canvas layout:** `CanvasLayout` computes grid positions (660x440
tiles). Tiles are positioned absolutely in a `ZStack` with `scaleEffect`
+ `offset` for zoom/pan. `Shift+scroll` zooms; plain scroll pans (unless
a terminal is focused, then it's terminal scrollback).

## Operations Runbook

How Tado actually runs once the user clicks the dock icon, what
each in-process worker does, when it fires, and how to inspect /
recover when something goes wrong. Lives next to Persistence so
you can correlate live state with on-disk artifacts.

### In-process workers (everything runs inside the .app)

There are **no separate daemons** to start; every long-running
worker is a tokio task launched by `bt-core`'s startup hook.

| Worker | Source | Cadence | What it does | Inspect via |
|---|---|---|---|---|
| **bt-core daemon** | `bt-core::rpc::run_daemon` | always (boot → quit) | Owns the SQLite vault, services every JSON-RPC call from CLIs / MCP / FFI | `Knowledge → System` "Vault status" + "Vault health" cards |
| **Enrichment workers** (4: extract, link, dedupe, decay) | `bt-core::enrichment::worker::spawn_workers` | poll `pending_enrichment` every 2s; decayer every 15min | Auto-extract typed entities + edges from new docs; link stub references; dedupe on content hash; soft-archive expired rows | Backfill chip on `Knowledge → System` (visible while queued+running > 0) |
| **Scheduler** | `bt-core::service::scheduler_tick` (no continuous task in v0.15; ticks fire on RPC + manual run-now) | manual + occurrence-driven | Materializes automation occurrences; runs the in-process executors | `Dome → Automation` (full CRUD) + `Knowledge → System` "Scheduler queue" card (queue depths + stale-lease count) |
| **Status-line snapshotter** | Python script at `<vault>/.bt/status/claude/tado-statusline.py` | every ~5s while a Claude Code session is running anywhere on the machine | Writes `<vault>/.bt/status/claude/latest/<tado-session-id>.json` so the Knowledge → System "Claude Agents" panel can show what's running | `Knowledge → System` "Claude Agents" panel (`agent_status` envelope) |
| **EventBus + deliverers** | `Events/EventBus.swift` + `Events/Deliverers/*.swift` | event-driven | Fans typed `TadoEvent`s to sound, dock badge, banner, NDJSON log, notifications history, real-time A2A socket | `tado-events` CLI; `Calendar → Ledger` mode; NDJSON tail at `<storage-root>/events/current.ndjson` |
| **EventsSocketBridge** | `Services/EventsSocketBridge.swift` | event-driven | Mirrors `EventBus` to `/tmp/tado-ipc-<pid>/events.sock` for external consumers | `tado-events` CLI; any `nc`-style reader |
| **Run / Dispatch event watcher** | `Events/RunEventWatcher.swift` | DispatchSource-debounced file watch | Diffs `state.json` / `phases/*.json` from active Eternal/Dispatch runs; emits typed events; mirrors retros into Dome | Cross-Run Browser extension; `Calendar` ledger |

### Migration procedure (adding a new schema version)

Every schema bump follows the same pattern. Source of truth is
`bt-core/src/migrations.rs`; current `LATEST_SCHEMA_VERSION` lives
at the top of that file.

1. **Bump `LATEST_SCHEMA_VERSION`** to the next integer (e.g. v24
   → v25).
2. **Add `pub fn migration_<N>(conn: &Connection) -> Result<()>`**
   that does additive DDL only — `CREATE TABLE IF NOT EXISTS`,
   `CREATE INDEX IF NOT EXISTS`, guarded `ALTER TABLE` (read
   `pragma table_info` first; only `ADD COLUMN` if absent). Never
   drop, never rename.
3. **Append the call** in `migrate(conn)` after the previous
   migration's call. Migrations run in order; failures abort.
4. **Pre-migration backup is automatic** — `MigrationRunner`
   triggers `BackupManager.createBackup(reason: "pre-migration")`
   before applying anything.
5. **Add a unit test** in the same `migrations.rs` mirroring
   existing patterns (`migration_22_creates_code_tables`,
   `migration_23_adds_lifecycle_columns_and_log_tables`,
   `migration_24_stamps_activation_log`).
6. **Activation marker** — if the migration semantically
   "activates" a feature (Phase 5 v24 did this for recipes), add
   a `INSERT OR IGNORE INTO schema_activation_log` row. Surfaces
   that need to wait for activation read this table.
7. **Bump CLAUDE.md** in the Knowledge & Memory section's "Schema
   is at version **N**" sentence.

### FFI contract

Direction matters. Three rules govern the Swift ↔ Rust boundary:

1. **Swift calls Rust via FFI shim, not JSON-RPC.** Any Rust
   capability the UI uses gets a `pub extern "C" fn
   tado_dome_<family>_<verb>` shim in `dome_ffi.rs`, a matching C
   declaration in `Sources/CTadoCore/include/tado_core.h`, and a
   typed `DomeRpcClient.<family><Verb>` Swift facade. The Unix
   socket is reserved for external callers (CLIs, MCP).
2. **Rust never calls Swift.** Information flows back via FFI
   return value (JSON string) or the `EventBus` (events the daemon
   emits → Swift subscribers consume). No Rust-initiated callbacks.
3. **Naming**:
   - Rust: `tado_dome_<family>_<verb>` (snake_case), e.g.
     `tado_dome_automation_run_now`, `tado_dome_recipe_apply`.
   - Swift facade: `<family><Verb>` (camelCase) on
     `DomeRpcClient`, e.g. `automationRunNow`, `recipeApply`.
   - JSON keys match the bt-core `serde::Serialize` field names
     (snake_case); Swift Codable uses `CodingKeys` to camelCase.
4. **cbindgen syncs the C header.** `Sources/CTadoCore/include/
   tado_core.h` is the public boundary; Rust additions to
   `dome_ffi.rs` get a matching block in the header within the
   same commit.

### Verification matrix

What MUST pass before a release ships. Listed in dependency order.

| Gate | Command | Catches |
|---|---|---|
| Rust compile | `cargo build --release -p bt-core -p tado-core` | FFI shim drift, missing header sync |
| Swift build | `cd /Users/miguel/Documents/tado && swift build` | C-header / Swift binding drift |
| bt-core unit | `cargo test -p bt-core` | service.rs invariants, migration drift |
| dome-eval lib | `cargo test -p dome-eval` | retrieval-quality regression (Phase 2 corpus) |
| Spawn-pack contract | `cargo test -p bt-core --test spawn_pack_byte_equiv` | byte-stability of preamble (rule 6) |
| Ingest scope contract | `cargo test -p bt-core --test ingest_scope_contract` | accidental global pollution rule |
| Live smoke | manual: launch app → Knowledge → System renders without errors | wiring drift, daemon-down behavior |

### Recovery procedures

For when production state goes sideways. Each procedure is
intended to be runnable cold by the operator without context.

| Symptom | Recovery |
|---|---|
| **Corrupt SwiftData cache** (Tado won't open, "DataStore: bad signature" or similar) | `rm -rf ~/Library/Application\ Support/Tado/cache/`. SwiftData rebuilds from the canonical JSON files on next launch. |
| **Stuck SQLite WAL** (vault file fine but daemon hangs) | Quit Tado (Cmd+Q) — v0.15 wires the `tado_dome_stop` checkpoint. If the WAL file is non-empty after exit, `sqlite3 ~/Library/Application\ Support/Tado/dome/.bt/index.sqlite "PRAGMA wal_checkpoint(TRUNCATE);"`. |
| **Lost daemon socket** (`/tmp/tado-ipc-<pid>/events.sock` gone) | Sockets are pid-scoped; relaunching the app remints them. CLI tools fail loudly until the new socket exists. |
| **Accidental global Dome ingestion** (the v0.10 "everything went to Global" foot-gun) | `Knowledge → System → Clear globally-ingested codebases (N)` — takes a backup snapshot first, then purges via `vault_purge_topic_scope` RPC. |
| **Migration aborted mid-flight** (`version` file at lower-than-LATEST) | Restore from `<storage-root>/backups/tado-backup-<date>-pre-migration.tar.gz` via Settings → Storage → "Restore from backup". |
| **Lost agent token secrets** | Secrets are hashed-only after issue; can't be recovered. Issue a new one via Settings → Agent tokens, copy at issue, revoke the old. |
| **Cross-Run Browser shows nothing** | Verify Eternal/Dispatch runs have valid `state.json`. RunEventWatcher debounce-watches; manually relaunching the app re-walks. |

## Persistence (settings / memory / events / Dome vault)

All canonical state lives under the **storage root**, by default
`~/Library/Application Support/Tado/`. Since v0.9.0 the root is
relocatable — `StorageLocationManager` reads
`<default-root>/storage-location.json`, and Settings → Storage →
Change Location… queues a move that runs pre-SwiftData on the next
launch (tarball backup, full copy + verify, atomic flip, source
prune):

```
settings/global.json          user-global settings (scope 4)
memory/user.md                user-level long-lived context
memory/user.json              user-level cached facts
events/current.ndjson         append-only event log (one JSON per line)
events/archive/*.ndjson       rotated daily
backups/tado-backup-*.tar.gz  auto-snapshot pre-migration + manual exports
cache/app-state.store         SwiftData store (rebuildable, not canonical)
dome/                         Dome vault (.bt/, topics/, index.sqlite)
storage-location.json         locator: activeRoot / pendingRoot / lastMoveError
version                       last-applied migration id
```

Per-project state lives under `<project>/.tado/`:

```
config.json                   project-shared settings (commit by default)
local.json                    project-local overrides (gitignored)
memory/project.md             long-lived project context
memory/notes/<ISO>-*.md       timestamped running notes
.gitignore                    auto-maintained by Tado (honors commitPolicy)
eternal/runs/<uuid>/          per-run state
dispatch/runs/<uuid>/         per-run state
```

**Scope hierarchy** (highest wins on merge): runtime > project-local >
project-shared > user-global > built-in default. Implemented in Swift
(`ScopedConfig`) and mirrored in Rust (`tado-settings::Scope`) so
non-Swift callers see the same precedence.

**Canonical store is JSON files on disk**, atomically written via
`AtomicStore` (Swift) or the matching Rust `tado-settings::write_json`
(temp + fsync + rename, with sidecar `.lock` flock). SwiftData is a
rebuildable cache fed by `AppSettingsSync` and `ProjectSettingsSync`. If
the SwiftData store corrupts, `rm -rf cache/` and relaunch — it
rebuilds from JSON.

**Event system** — every meaningful state transition
(`terminal.completed`, `eternal.phaseCompleted`, `ipc.messageReceived`,
`dome.daemonStarted`, user broadcasts) publishes a typed `TadoEvent`
through `EventBus`. Deliverers subscribe: `SoundPlayer` (audio),
`DockBadgeUpdater` (unread count), `SystemNotifier` (macOS banner),
`InAppBannerOverlay` (transient pill), `EventPersister` (NDJSON log),
`EventsSocketBridge` (real-time fanout to subscribers on
`/tmp/tado-ipc/events.sock`). Routing + mute + quiet hours are
configured in `global.json → notifications`.

## Knowledge & Memory (Dome second brain + spawn-time context)

This section is the persistence layer's *semantic* counterpart: where
Persistence stores facts, Knowledge stores *what's been learned*. Every
agent that wakes up inside a Tado-spawned tile inherits this layer
automatically — but agents only use it deliberately if their project
docs document it (which is what "Bootstrap knowledge layer" exists to
do).

**`bt-core` runs in-process** inside the Tado `.app` (booted by
`DomeExtension.onAppLaunch` via the FFI entry `tado_dome_start`). Vault
is at `<storage-root>/dome/`, the Unix socket at
`<vault>/.bt/bt-core.sock`. Schema is at **version 23** as of v0.10.0
(v22 added codebase indexing tables; v23 adds the Knowledge Catalog
foundation — lifecycle columns on `graph_nodes`, provenance columns
on `graph_edges`, plus the `retrieval_log`, `pending_enrichment`,
`retrieval_recipes` tables that v0.12+ enrichment workers and the
v0.14 governed-answer tools build on). New chunks use
Qwen3-Embedding-0.6B (1024-dim) while legacy 384-dim `noop@1` rows
continue to work. The "Bootstrap vectors" button on Dome → Knowledge
re-embeds every legacy chunk through the live model.

**Hybrid search (v0.10+)** combines `note_chunks` cosine + FTS5 BM25
with a heuristic rerank: `combined_score × (0.5 + 0.5·freshness) ×
scope_match × confidence × supersede_penalty`. Freshness is
exponential decay (30-day half-life) over the most recent of
`updated_at` / `last_referenced_at` / `created_at`. Scope match
boosts hits in the caller's preferred scope (1.0× vs 0.6×).
Confidence and supersede penalty are read from `graph_nodes` (Phase
3 wired the entity layer that backs them — confidence defaults to
1.0 when no typed entity exists; superseded rows get a 0.3× penalty
so retired facts stay visible for audit but rank below replacements).
`HybridQuery::ctx` is optional — when set, hybrid search applies the
rerank and writes one row to `retrieval_log` (actor, query, ranked
results, latency, optional `pack_id`). `dome-mcp::dome_search` always
sets the ctx with `tool: "dome_search"`. When `agent.context_event`
fires with `event_kind = 'agent_used_context'`, the consumed node's
`last_referenced_at` bumps and the matching `retrieval_log.was_consumed`
flips to 1 — implicit-feedback hook for the `dome-eval` CLI.

**Retrieval recipes (Phase 5, v0.10+)** — intent-keyed retrieval
policies with template-rendered governed answers (Tado's analog of
Knowledge Catalog "verified queries"). Three baseline intents ship
baked into bt-core: `architecture-review`, `completion-claim`,
`team-handoff`. Each carries a `RetrievalPolicy`
(topics, knowledge kinds, scope, freshness decay, minimum-confidence
threshold) and a markdown template at
`tado-core/crates/bt-core/recipes/<intent>.md`. The runner
(`bt_core::recipes::apply_recipe`) executes the policy via
`hybrid_search` with rerank, separates hits into citations vs
`missing_authority`, and renders the template into a
`GovernedAnswer`. No LLM — synthesis is deterministic substitution
(`{{ var }}` + `{{ list | bullets(N) }}`). Two MCP tools:
`dome_recipe_list` and `dome_recipe_apply`. Per-project overrides
land at `<project>/.tado/verified-prompts/<intent>.md`. Schema is
at version **24** (Phase 5 activation marker). **v0.11+** adds a
human surface: `Dome → Recipes` lists every recipe in the active
scope, shows the policy summary, runs the recipe with one click,
and renders the `GovernedAnswer` with citations + missing-authority
callouts. FFI: `tado_dome_recipe_list`, `tado_dome_recipe_apply`,
`tado_dome_recipe_seed_defaults`.

**Automation (v0.11+)** — bt-core has shipped an in-process scheduler
since v0.9 (`automation_*` methods in `service.rs:9663+`,
`scheduler_tick` at `service.rs:10985`). v0.11 adds the operator UI
that's been missing: `Dome → Automation`. Card list of every
defined automation, an inline create/edit sheet, a `⋯` menu with
Pause/Resume/Run-now/Edit/Duplicate/Delete (destructive guard rails
on Delete via `NSAlert`), and a unified occurrence ledger across
every automation showing planned/started/finished/run-id/failure
fields with a "Retry" button on failed/cancelled rows. All actions
go through `swift_ui_actor()` so every operator move lands in the
audit log under `actor=user_ui`. FFI: 9 new shims under
`tado_dome_automation_*` (`list/get/create/update/delete/
set_paused/run_now/occurrence_list/retry_occurrence`).

**Spawn-pack engine v2 (Phase 4, v0.10+)** — the Rust pack engine
at `tado-core/crates/bt-core/src/context/` produces the
`<!-- tado:context:begin -->` / `<!-- tado:context:end -->` block
byte-identically to the v0.10 Swift composer. Cached in-memory
keyed by `(project_id, agent_name)`, TTL 60 s, invalidated by
`note_supersede` / `note_verify` / `node_decay`. Feature-flagged
via `GlobalSettings.dome.contextPacksV2` (default `false` until
v0.11) and `TADO_DOME_CONTEXT_PACKS_V2=1` env override. Both sides
share a deterministic relative-time formatter (`{n}m ago` / `{n}h
ago` / `{n}d ago` / etc.) so locale doesn't drift the bytes. Pin
contract: `bt-core/tests/spawn_pack_byte_equiv.rs`.

**Dome lifecycle (Phase 3, v0.10+)** — `graph_nodes` carries
`confidence`, `superseded_by`, `supersedes`, `expires_at`,
`archived_at`, `content_hash`, `last_referenced_at`,
`entity_version`. Three new MCP tools manage these fields:
- `dome_supersede(old_id, new_id, reason?)` chains an old fact to
  its replacement; rerank demotes the old row 0.3×.
- `dome_verify(node_id, verdict, agent_id?, reason?)` lifts
  confidence to ≥ 0.9 (`confirmed`) or floors at ≤ 0.4 (`disputed`).
- `dome_decay(node_id, reason?)` soft-archives a node.

Background enrichment runs as four tokio workers under
`tado-core/crates/bt-core/src/enrichment/` (extractor, linker,
deduper, decayer). They drain `pending_enrichment` at low priority
on a 2 s polling tick (decayer is 15 min) — every doc write
auto-enqueues an extract + link + dedupe job. Failures land in
`pending_enrichment.last_error`; no watchdog or auto-retry per
project conventions. The Knowledge → System surface shows a
backfill chip whenever `queued + running > 0`.

**Auto-seeded topics:** every project gets a `project-<shortid>` topic
on registration; teams add `team-<sanitized-name>` notes; Eternal sprint
+ completion retros mirror as structured notes via `RunEventWatcher`.
Scoped knowledge — `global` vs `project` — is a v0.9.0 addition;
`DomeScopeSelection` is the Swift facade and the user picks via the
Dome surface's scope selector (with optional "include global with
project" merge).

**Spawn-time context preamble** — every non-Eternal Tado spawn has a
markdown block prepended to the user's prompt
(`DomeContextPreamble.swift`, plumbed in `MetalTerminalTileView.swift`).
Contains identity + project info + team info + recent project notes
pulled from `dome_search --topic project-<shortid>`, capped at ~1500
tokens, wrapped in `<!-- tado:context:begin -->` / `<!-- tado:context:end -->`
markers. Dome offline → preamble is silently skipped.

**Read paths** (use any one — all hit the same vault):

- **MCP tools** (preferred when in Claude Code): `dome_search`,
  `dome_read`, `dome_note`, `dome_schedule`, `dome_graph_query`,
  `dome_context_resolve`, `dome_context_compact`, `dome_agent_status`.
  Auto-registered at user scope on first launch via
  `claude mcp add dome` ([DomeExtension.swift:215-223](Sources/Tado/Extensions/Dome/DomeExtension.swift:215)).
  Agents *must* use the latter four before making stale architecture
  or completion claims.
- **CLI** (`tado-dome` at `~/.local/bin/`): `tado-dome query "<text>"
  [--topic <name>] [--scope global|project] [--limit N]`,
  `tado-dome read <note-id>`, `tado-dome register --topic <topic>
  --note "<markdown>"`. Designed for Codex and shell scripts that don't
  speak MCP.
- **Project-local memory** (`.tado/memory/`): `tado-memory
  {read,note,search,path}` (CLI) and `tado_memory_*` (MCP). These
  write plain markdown into the project tree; `RunEventWatcher`
  mirrors them into Dome on the next sync.

**Status snapshots** — Claude Code's `statusLine` config is auto-wired
to a Tado-shipped Python script at
`<vault>/.bt/status/claude/tado-statusline.py` (see
[DomeExtension.swift:154](Sources/Tado/Extensions/Dome/DomeExtension.swift:154)
and [dome_ffi.rs:1097](tado-core/crates/tado-terminal/src/dome_ffi.rs:1097)).
Every Claude Code session anywhere on the user's machine writes
`{captured_at, model, ctx_pct, cost, ...}` to
`<vault>/.bt/status/claude/latest/<tado-session-id>.json` every ~5s.
The Knowledge → Agent System surface reads those files via
`dome_agent_status` to show what's running.

## Memory (vault layout, scope, lifecycle, rerank)

Tado's "memory" is the in-process Dome vault — a SQLite + chunked-
markdown store that holds every typed fact + retrieval signal the
app accumulates. This section is the agent-facing reference for
*where* memory lives and *how* it's ranked when an agent reads.

### Vault layout (on disk)

```
<storage-root>/dome/                   # Dome vault root
  .bt/
    index.sqlite                       # SQLite state (schema v24)
    bt-core.sock                       # Unix socket the daemon listens on
    audit.log                          # NDJSON audit events (every write)
    config.toml                        # Tokens + caps + feature flags
    status/claude/latest/<sid>.json    # Per-session statusLine snapshots
  topics/<topic>/<slug>/                # Doc folders (one per registered note)
    user.md                             # Human-authored side
    agent.md                            # Agent-authored side
    meta.json                           # Tags + links_out + status
  inbox/                                # Manual import drop zone
```

### Scope hierarchy (5 levels, highest wins on merge)

`runtime > project-local > project-shared > user-global > built-in default`.

- **runtime** — in-memory overrides set during a session.
- **project-local** — `<project>/.tado/local.json` (gitignored).
- **project-shared** — `<project>/.tado/config.json` (committed).
- **user-global** — `<storage-root>/settings/global.json`.
- **built-in default** — hard-coded in `GlobalSettings.swift` /
  `tado-settings::Scope`.

Implemented as `ScopedConfig` (Swift) and mirrored in Rust as
`tado-settings::Scope`. Every read merges the chain on demand.

### Graph entity layer

Migrated to `graph_nodes` + `graph_edges` in v22; lifecycle
columns added in v23 (Phase 3). Typed entities ride on top of
plain "doc" nodes:

| `graph_nodes.kind` | Meaning |
|---|---|
| `doc` | Generic note (one per doc) |
| `decision` | `## Decision: …` heading extracted by the Phase-3 enricher |
| `intent` | `## Intent: …` heading |
| `outcome` | `## Outcome: …` |
| `retro` | Eternal/Dispatch retro mirrored in by RunEventWatcher |
| `note` / `topic` / `agent` / `brand` / `event` | Pre-existing entity nodes |

Lifecycle columns (every node): `confidence` (default 0.7),
`superseded_by` / `supersedes` (chain pointers), `expires_at`
(TTL), `archived_at` (soft-delete), `content_hash` (dedup),
`last_referenced_at` (read-time signal), `entity_version`.

### Lifecycle primitives (Phase 3 MCP tools)

Surfaced both via MCP and in the UI (Knowledge surfaces).

- **`dome_supersede(old_id, new_id, reason?)`** — chains an old
  fact to its replacement. Rerank then demotes the old row 0.3×
  so retired facts stay visible for audit but never outrank
  replacements.
- **`dome_verify(node_id, verdict, agent_id?, reason?)`** — flips
  `confidence` to ≥ 0.9 (`confirmed`) or ≤ 0.4 (`disputed`).
- **`dome_decay(node_id, reason?)`** — soft-archives the node.

### Rerank formula (v0.10+)

Every hybrid_search hit goes through this ranker before the top
N return:

```
combined_score
  × (0.5 + 0.5 · freshness)
  × scope_match
  × confidence
  × supersede_penalty
```

- **freshness** — exponential decay with 30-day half-life over
  the most recent of `updated_at` / `last_referenced_at` /
  `created_at`.
- **scope_match** — 1.0× if the hit's scope matches the caller's
  preferred scope, 0.6× otherwise.
- **confidence** — read from `graph_nodes.confidence`. Defaults
  to 1.0 when no typed entity exists.
- **supersede_penalty** — 0.3× if the row's `superseded_by` is
  set, 1.0× otherwise.

Implemented in `bt-core/src/notes/search.rs::rerank`. Every
`hybrid_search` call also writes one row to `retrieval_log` —
that's the corpus `dome-eval replay` uses to score quality.

## Context Lifecycle (full agent journey)

End to end, here's what happens when a Tado tile spawns and
runs an agent that consumes Dome context:

1. **Spawn** — `MetalTerminalTileView` renders a new terminal,
   prepends the spawn-pack preamble to the user prompt.
2. **Pack composition** — `compose_spawn_preamble` (Rust, byte-
   equivalent to Swift fallback) renders identity + project +
   team + recent project notes + retrieval contract into the
   `<!-- tado:context:begin -->`…`<!-- tado:context:end -->`
   block. Cached in `context_packs` keyed by `(project_id,
   agent_name)`, TTL 60s.
3. **Preamble injection** — `ProcessSpawner` shells the prompt
   into `claude` / `codex`. Agent sees the preamble first.
4. **MCP retrieval** — Agent calls `dome_search` /
   `dome_recipe_apply` / `dome_graph_query` via `dome-mcp`. Each
   call writes a `retrieval_log` row with `tool`, `query`,
   `result_ids`, `latency_ms`, `was_consumed=0`.
5. **Consumption** — When the agent acts on a retrieval result
   (cites it, edits the referenced doc, etc.), it calls
   `agent_context_event(event_kind='agent_used_context')`. Bt-core
   bumps `last_referenced_at` on the consumed node and flips
   `was_consumed=1` on the matching `retrieval_log` row.
6. **Enrichment** — On every `dome_note_write`, four jobs land in
   `pending_enrichment`: extract (parse Markdown headings →
   typed entities), link (resolve `dome://note/<id>` references),
   dedupe (content-hash collisions), backfill if migrating.
   Workers drain at 2-second intervals.
7. **Supersede / verify / decay** — When a new fact replaces an
   old one, the agent (or operator via `Dome → Knowledge → List`)
   calls `dome_supersede`, which invalidates the spawn-pack cache
   for the affected project so the next tile spawn picks up the
   new authority.
8. **Audit** — Every step lands a row in `audit.log` (NDJSON) +
   bt-core's `audit` table. Operator can grep both via
   `Knowledge → System → Audit log` (last 200 rows, prefix
   filter).
9. **Eval** — Periodically (or on-demand via `Knowledge → System
   → Run eval`), `dome-eval replay` scores recent retrievals:
   P@5, R@10, nDCG, mean latency, consumption rate. Regression
   over 5% blocks the next release per the verification matrix.

## Tado A2A (CLI + MCP + real-time events)

Tado exposes three coordinated A2A surfaces. They share data — every
event, send, and broadcast hits the same in-process `EventBus` and
`IPCBroker` — but each surface answers a different question.

### CLI (`~/.local/bin/`)

```bash
tado-list                                         # Active sessions (UUID, engine, grid, status, name)
tado-list --toon                                  # AXI-style compact output (~45% fewer tokens)
tado-read <target> [--tail N] [--follow] [--raw]  # Read terminal output from a session
tado-send <target> <message>                      # Send typed input to a terminal session
tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]
tado-events [filter]                              # Subscribe to /tmp/tado-ipc/events.sock; filter = "*", "topic:foo", "session:<id>", or kind prefix
tado-config {get,set,list,path,export,import} [scope] [key] [value]
tado-notify {send "<title>", tail}
tado-memory {read,note,search,path} [scope]
tado-dome {register,query,...}                    # Scoped Dome knowledge from canvas agents
```

**Target resolution** (same for `tado-read` and `tado-send`, in
priority order):

1. Exact UUID
2. Grid coordinates: `1,1` or `1:1` or `[1,1]`
3. Name substring match

**Examples:**

```bash
tado-read 1,1                              # Read full output from terminal at grid [1,1]
tado-read 1,1 --tail 50                    # Last 50 lines only
tado-read hello --follow                   # Live-stream output (like tail -f)
tado-read 1,1 --raw                        # Include ANSI escape codes (default: stripped)
tado-send 1,1 "hello from another agent"   # Send to terminal at grid [1,1]
tado-send hello "follow-up prompt"         # Send to session whose name contains "hello"
tado-deploy "implement auth module" --agent backend
tado-events "team:core"                    # Live event stream filtered to team
tado-events "kind:terminal."               # Live event stream filtered by kind prefix
```

**Typical workflow for responding to a terminal:** `tado-read 1,1` to
see what it output, then `tado-send 1,1 "your response"` to reply.

**Deploying agents:** `tado-deploy` is a Tado IPC command that creates
a new terminal tile on the Tado canvas — it is NOT your built-in
subagent or background agent tool. Use it to deploy a new agent session
that gets its own tile, grid position, and IPC registration. Defaults
(project, team, engine, cwd) are inherited from the calling session's
environment. The agent name corresponds to definitions at
`.claude/agents/<name>.md`.

**Fire-and-forget pattern:** When deploying, include in the deployed
agent's prompt instructions to deliver results back via `tado-send
<your-grid>`. Then STOP — do not wait, do not run tado-list, do not
read the deployed agent's terminal log. The deployed agent will
`tado-send` results back to you, which will wake you. Example:
`tado-deploy "analyze the codebase and deliver results via tado-send 1,1" --agent analyst`

**Contacting other agents:** When you send a message via `tado-send`,
always identify yourself and tell the recipient how to respond. Include
your grid position (e.g., `[1,1]`), your project, and instruct them to
reply with `tado-send <your-grid> "<response>"`. The receiving agent
has no context about who sent the message unless you include it. Once a
conversation is established, you can skip the full introduction.

**Responding to agent requests:** When another agent sends you a
message asking for something, you **must** deliver the requested
information back via `tado-send <their-grid> "<response>"`. This is
not optional — the requesting agent is waiting. Do not just print the
answer in your own terminal; send it back to them.

**Working in a team:** When you are part of a team, you share a project
with other specialized agents. Know your teammates — read their agent
definitions at `.claude/agents/<name>.md` to understand their roles.
Use `tado-list` to find running teammates. When a teammate asks you for
something, deliver it back to them via `tado-send`. When you need
something from a teammate, send a request and they will deliver back to
you.

### MCP bridges (Rust `[[bin]]`s, auto-registered)

Both bridges are stdio Rust binaries inside the bundled `.app` — no
Node runtime, no separate install. They auto-register into Claude Code
at user scope on first launch (silent fallback if `claude` CLI is
missing).

- **`tado-mcp`** exposes: `tado_config_{get,set,list}`,
  `tado_memory_{read,append,search}`, `tado_notify`,
  `tado_events_query`, `tado_list`, `tado_send`, `tado_read`,
  `tado_broadcast`. Use it to script the surface above without shelling
  out.
- **`dome-mcp`** exposes: `dome_search`, `dome_read`, `dome_note`,
  `dome_schedule`, `dome_graph_query`, `dome_context_resolve`,
  `dome_context_compact`, `dome_agent_status`. Agents must use the
  latter four before making stale architecture or completion claims.

### Real-time events

`tado-events` and `EventsSocketBridge` (`/tmp/tado-ipc/events.sock`)
fan the in-process `EventBus` to local subscribers. Useful for reactive
teammates, audit trails, and fan-in coordination patterns. Pair with
`tado-send --broadcast` (filterable by `--project` / `--team`) for
proper pub/sub.

### IPC internals

File-based via `/tmp/tado-ipc/`. Each session has `inbox/`, `outbox/`,
and `log` in its directory. Terminal output is flushed to the `log`
file every 5 seconds. External messages go to `/tmp/tado-ipc/a2a-inbox/`.
See [IPCBroker.swift](Sources/Tado/Services/IPCBroker.swift) and
[IPCMessage.swift](Sources/Tado/Models/IPCMessage.swift).

## Bootstrapping a project (the four `Bootstrap …` actions)

Every project gets a `⋯` menu (in `ProjectCard` and `TopNavBar`) with
four bootstrap actions. Each one spawns a one-shot agent tile that
edits the target project's `CLAUDE.md` / `AGENTS.md` / `.claude/`
configuration. None of them mutate code; they all stop after writing.
Prompts are authored in
[ProcessSpawner.swift](Sources/Tado/Services/ProcessSpawner.swift) so
they version-bump alongside the rest of the codebase, and they're
glued to the menu via
[ProjectActionsService.swift](Sources/Tado/Services/ProjectActionsService.swift).

| Action | Spawned cwd | Targets | When to run |
| --- | --- | --- | --- |
| **Bootstrap A2A tools** | Tado repo | project's `CLAUDE.md` + `AGENTS.md` | Once per new project — installs Tado A2A docs (CLI tools, MCP bridges, real-time events, broadcast). |
| **Bootstrap team awareness** | project root | project's `CLAUDE.md` + `AGENTS.md` | After teams or roster change — re-injects roster + coordination patterns + Dome team-topic search. Disabled when no teams. |
| **Bootstrap Claude auto mode** | project root | `~/.claude/settings.json` + `<project>/.claude/settings.local.json` | When configuring a project for Continuous Eternal runs — installs `permissions.defaultMode = auto` plus the `autoMode.environment` trust prose. Pinned to Opus 4.7 + skip-permissions because subtle JSON merge mistakes break everything. |
| **Bootstrap knowledge layer** | project root | project's `CLAUDE.md` + `AGENTS.md` | Once per new project — teaches the project's agents that Dome exists, what's already in it, how to read with `dome_search` / `tado-dome`, and how to write retros with `dome_note` / `tado-dome register`. |

When you ship a tool, surface, or convention that agents should know
about, refresh the corresponding `bootstrap*Prompt` function and bump
the project's bootstraps — old projects need to re-run them to pick up
the new shape.

## Extensions (Notifications, Dome, Cross-Run Browser)

Extensions are the home for optional surfaces. They conform to
`AppExtension` ([AppExtensionProtocol.swift](Sources/Tado/Extensions/AppExtensionProtocol.swift)),
appear in the in-app extension page
([ExtensionsPageView.swift](Sources/Tado/Extensions/ExtensionsPageView.swift)),
and register at compile time via
[ExtensionRegistry.swift](Sources/Tado/Extensions/ExtensionRegistry.swift).
Each extension can declare a window in `TadoApp.body` keyed by
`ExtensionWindowID`.

Currently shipped:

- **Notifications** — banner overlay + history. See
  [NotificationsExtension.swift](Sources/Tado/Extensions/Notifications/NotificationsExtension.swift)
  and [NotificationsWindowView.swift](Sources/Tado/Extensions/Notifications/NotificationsWindowView.swift).
- **Dome** — the User Notes / Agent Notes / Calendar / Knowledge
  surfaces, the auto-statusLine installer, the Bootstrap-vectors
  button, the Ingest-codebase flow. See
  [DomeExtension.swift](Sources/Tado/Extensions/Dome/DomeExtension.swift)
  and [Surfaces/](Sources/Tado/Extensions/Dome/Surfaces/).
- **Cross-Run Browser** — global timeline of every Eternal/Dispatch run
  across every project. See
  [CrossRunBrowserExtension.swift](Sources/Tado/Extensions/CrossRunBrowser/CrossRunBrowserExtension.swift)
  and [CrossRunBrowserView.swift](Sources/Tado/Extensions/CrossRunBrowser/CrossRunBrowserView.swift).

## Execution (build matrix, verification, rollback)

The complete dev → release loop. Use this when you need a single
place to look up "how do I check that this PR is good".

### Build matrix

| Step | Command | When to run |
|---|---|---|
| Swift compile | `cd /Users/miguel/Documents/tado && swift build` | Every Swift edit |
| Swift run | `swift run` | Quick sanity check (sub-2s relink) |
| Rust core (debug) | `cd tado-core && cargo build -p tado-core` | Every Rust edit on the FFI side |
| Rust core (release) | `cd tado-core && cargo build --release -p bt-core -p tado-core` | Before linking the Swift app, before any release tag |
| MCP bridges | `make mcp` (= `cargo build --release -p dome-mcp -p tado-mcp`) | When agent-facing MCP shape changes |
| Full dev loop | `make dev` | One-shot: cargo release + cbindgen header sync + swift run |

### Test matrix

Run all of these green before tagging:

```bash
cd tado-core
cargo test -p bt-core                              # 132+ unit + integration
cargo test -p bt-core --test spawn_pack_byte_equiv # spawn-pack contract (4 fixtures)
cargo test -p bt-core --test ingest_scope_contract # ingest scope locked
cargo test -p dome-eval                            # corpus regression
cargo test -p tado-ipc -p tado-settings            # contract types + atomic IO
```

### Live verification ritual

Manually check before every release:

1. Launch the freshly-built app.
2. Open `Dome → Knowledge → System`. Verify:
   - "Vault status" card shows your vault path + non-zero doc count.
   - "Vault health" card all green.
   - "Scheduler queue" card shows queue depths.
   - "Run eval" with `Last 24h` populates (or shows the empty-state hint).
   - "Audit log" shows recent rows.
3. `Dome → Automation`: card list renders if you have any automations; "+ New automation" sheet opens.
4. `Dome → Recipes`: 3 baked defaults (architecture-review, completion-claim, team-handoff) appear in the left rail.
5. `Settings → Agent tokens`: existing tokens listed; `Issue token` form works.
6. Cmd+Q → relaunch → repeat 2 (state must persist).

### Rollback procedure

When a release breaks something:

1. **Cosmetic / non-data bug** — fix forward in the next patch
   release.
2. **Data corruption / migration regression** — restore the most
   recent `<storage-root>/backups/tado-backup-<date>-pre-migration.tar.gz`
   via Settings → Storage → "Restore from backup". Then revert
   the offending tag (`git revert v0.X.Y`) and ship a patch.
3. **Compile-time blocker** — ship a hotfix from `master~1`. Do
   NOT force-push the master branch.

### Releasing ("release next version")

The exact procedure (also documented in [Releasing](#releasing-release-next-version) below). Listed here so it's part of the Execution checklist:

1. Read CHANGELOG → bump to next minor version.
2. Audit: `git status`, `git log v<prev>..HEAD`.
3. Verify: `swift build` + `make mcp` + the test matrix above.
4. Keep `.tado/eternal/` / `.tado/dispatch/` / `.tado/memory/notes/` gitignored.
5. Update CHANGELOG.md with `### Added / Changed / Fixed / Removed` sections.
6. Stage explicitly by path; `git rm` for intentional deletions.
7. Commit with `Release vX.Y.Z — <headline>` subject.
8. Annotated tag: `git tag -a vX.Y.Z -m "..."`.
9. Push: `git push origin master && git push origin vX.Y.Z`.
10. Create GitHub release: `gh release create vX.Y.Z --title "X.Y.Z" --notes-file ...` (title is bare version, body is unaltered CHANGELOG section).
11. Verify with `gh release view vX.Y.Z`.

## Key Files

**Spawning + sessions**
- `Services/ProcessSpawner.swift` — builds the CLI command for the selected engine; shell-escapes flags; hosts the four `bootstrap*Prompt` strings and the dispatch architect prompt
- `Services/TerminalManager.swift` — session lifecycle, registry sync, idle detection
- `Services/ProjectActionsService.swift` — the four `Bootstrap …` actions + delete-project
- `Models/TerminalSession.swift` — session model + status FSM (`pending` / `running` / `needsInput` / `awaitingResponse` / `completed` / `failed`) + prompt queue

**Renderer**
- `Rendering/MetalTerminalView.swift` / `MetalTerminalTileView.swift` / `MetalTerminalRenderer.swift` — Metal pipeline (also: tile-side prepends Dome context preamble before the prompt)
- `Rendering/GlyphAtlas.swift` + `Shaders.metal` — glyph cache + shaders
- `Rendering/FontMetrics.swift` — monospace font metrics via `NSFont.monospacedSystemFont`
- `tado-core/crates/tado-terminal/src/{ffi,grid,performer,pty,session}.rs` — Rust PTY + VT parser + cell grid

**Canvas + UI**
- `Views/CanvasView.swift` + `CanvasLayout` — grid position math, zoom/pan, tile placement
- `Views/SidebarView.swift` — projects, teams, sessions, notifications bell
- `Views/SettingsView.swift` — picker grids, storage relocator, notifications routing
- `Views/TopNavBar.swift` — top-of-window project actions menu (the four `Bootstrap …` entries live here)
- `Views/Projects/ProjectCard.swift` + `ProjectListView.swift` — list-view project cards (mirror of the menu above)

**IPC + extensions**
- `Services/IPCBroker.swift` — file-based broker, a2a inbox watcher, CLI tool generation
- `Services/EventsSocketBridge.swift` — fans `EventBus` to `/tmp/tado-ipc/events.sock`
- `Services/TadoMcpAutoRegister.swift` — auto-`claude mcp add tado` on launch
- `Models/IPCMessage.swift` — IPC envelope + registry types
- `tado-core/crates/tado-ipc/src/` — Rust mirror of IPC contract + registry serialization
- `Extensions/AppExtensionProtocol.swift` + `ExtensionRegistry.swift` + `ExtensionsPageView.swift` — extension host
- `Extensions/Notifications/NotificationsExtension.swift` + `NotificationsWindowView.swift` — notifications surface
- `Extensions/Dome/DomeExtension.swift` + `DomeRpcClient.swift` + `Surfaces/*` — Dome surfaces (User Notes, Agent Notes, Calendar, Knowledge)
- `Extensions/Dome/DomeContextPreamble.swift` — spawn-time markdown block prepended to every prompt
- `Extensions/Dome/DomeScopeSelection.swift` — global vs project scope (with includeGlobal merge)
- `Extensions/CrossRunBrowser/CrossRunBrowserExtension.swift` + `CrossRunBrowserView.swift` — global run timeline

**Persistence + events**
- `Persistence/StorageLocation.swift` — relocator (locator file + scheduled move + verify)
- `Persistence/StorePaths.swift` — derived paths under the active storage root
- `Persistence/AtomicStore.swift` — atomic write + flock (shared Swift / CLI / bash)
- `Persistence/ScopedConfig.swift` — 5-scope config facade
- `Persistence/FileWatcher.swift` — debounced DispatchSource wrapper
- `Persistence/AppSettingsSync.swift` / `ProjectSettingsSync.swift` — JSON ↔ SwiftData bridges
- `Persistence/MigrationRunner.swift` + `Migrations/` — monotonic migration runner (auto-backup pre-apply)
- `Persistence/BackupManager.swift` — tarball snapshot + restore
- `Events/EventBus.swift` + `Events/TadoEvent.swift` — pub/sub hub
- `Events/EventPersister.swift` — NDJSON appender + daily rotation
- `Events/Deliverers/{SoundPlayer,DockBadgeUpdater,SystemNotifier}.swift`
- `Events/RunEventWatcher.swift` — diffs `state.json` / `phases/*.json` to emit Eternal/Dispatch events; mirrors retros to Dome

**Rust workspace**
- `tado-core/crates/bt-core/src/{service.rs,db.rs,migrations.rs,notes/*}` — trusted-mutator daemon
- `tado-core/crates/tado-terminal/src/{dome_ffi,sibling_ffi}.rs` — FFI bridge to Swift (note: `dome_ffi.rs` hosts `tado_dome_install_status_line_script` and the embedded Python statusLine source)
- `tado-core/crates/dome-mcp/src/main.rs` — stdio MCP bridge (8 tools)
- `tado-core/crates/tado-mcp/src/main.rs` — stdio MCP bridge (12 tools)
- `tado-core/crates/tado-dome/src/main.rs` — scoped-knowledge CLI for canvas agents

## Releasing ("release next version")

When the user says "release next version", "release v0.X.Y", or "ship a
release", follow this exact flow end-to-end. No plan mode, no
confirmation prompts — this is a documented release procedure.

1. **Read `CHANGELOG.md`** to find the current top version. The next
   version is a minor bump by default (e.g. `0.8.0 → 0.9.0`). Only
   bump the major when the user explicitly asks.
2. **Audit the working tree**: `git status`, `git log v<prev>..HEAD`.
   Identify every uncommitted source change, every untracked source
   file, and every relevant commit since the previous tag.
3. **Verify the build**: `swift build` (Swift app) and
   `make mcp` (`cargo build --release -p dome-mcp -p tado-mcp` — both
   stdio bridges, both Rust). Do not release if either fails —
   fix first. (The Node `tado-mcp/` tree is kept as reference but
   unused; the bundled `.app` ships only the Rust binaries.)
4. **Keep runtime artifacts out** — make sure `.tado/eternal/`,
   `.tado/dispatch/`, and `.tado/memory/notes/` are gitignored. Any
   new per-run runtime directory should be added to `.gitignore`
   before staging.
5. **Update `CHANGELOG.md`**: insert a new `## [X.Y.Z] - YYYY-MM-DD`
   section at the top (above the previous version). Categorize under
   `### Added` / `### Changed` / `### Fixed` / `### Removed`. Each
   bullet leads with the feature in bold and explains the *why* in
   one to three sentences — a user reading release notes should be
   able to tell whether a change affects them without opening a diff.
6. **Stage explicitly by path** (not `git add -A`). Include source,
   `CHANGELOG.md`, `CLAUDE.md` (if updated), `docs/` additions, and
   MCP `src/` + `dist/`. Use `git rm` for intentional deletions.
7. **Commit with a release message**:
   - Subject: `Release vX.Y.Z — <short headline>`
   - Body: summary paragraph + bulleted highlights grouped by
     subsystem, each bullet 2–5 lines explaining *what* shipped and
     *why* it matters. Co-author trailer with
     `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
8. **Tag annotated**: `git tag -a vX.Y.Z -m "Tado vX.Y.Z — <headline>\n\n<3-5 line blurb pointing to CHANGELOG.md>"`.
9. **Push**: `git push origin master && git push origin vX.Y.Z`.
10. **Create the GitHub Release** (mandatory — the tag alone won't
    flip the "Latest" badge on github.com):
    ```bash
    awk '/^## \[X\.Y\.Z\]/,/^## \[<prev>\]/' CHANGELOG.md \
      | sed '$d' > /tmp/tado-release.md
    gh release create vX.Y.Z --title "X.Y.Z" \
      --notes-file /tmp/tado-release.md
    ```
    **Title is just the bare version** (e.g. `0.8.0`) — no prefix, no
    headline. All prose lives in the description, which is the
    unaltered CHANGELOG section.
11. **Verify**: `gh release view vX.Y.Z` — confirm title is the bare
    version, body matches CHANGELOG, and the release is not marked
    as draft/prerelease.

## Release history (one line per version)

Most recent first. Full notes for each version live in `CHANGELOG.md`;
this list is the at-a-glance "what changed at this version" reference
that lets you orient before reading the full diff.

- **v0.16.1** (2026-04-28) — *Hardening pass.* Four bugs / gaps
  fixed: `tado_dome_stop` actually runs `PRAGMA wal_checkpoint
  (TRUNCATE)` now (was a no-op stub despite v0.15's CHANGELOG
  claim); `graphLinks` Swift binding shape corrected to match
  bt-core's `{to, kind}` legacy-table return; orphan
  `tado_dome_system_runtime_envelope` FFI shim removed (no
  Swift caller); new **Settings → MCP tools inspector**
  shipping a static reference list of all 30 dome-mcp +
  tado-mcp tools with filter-by-prefix.
- **v0.16.0** (2026-04-28) — *Surface Coverage Pass, phase 6 —
  CLAUDE.md operations rewrite.* Major doc upgrade: new **Rules**
  checklist (10 hard rules including the FFI ↔ UI parity rule
  that drove this whole pass), new **Operations Runbook** (every
  in-process worker, the migration procedure, the FFI contract,
  the verification matrix, recovery procedures), new **Memory**
  section (vault layout, scope hierarchy, graph entity layer,
  lifecycle primitives, rerank formula), new **Context Lifecycle**
  walkthrough (the full agent-context journey from spawn → pack
  → MCP retrieval → consumption → enrichment → supersede → audit
  → eval), and new **Execution** section (build matrix, test
  matrix, live verification ritual, rollback procedure). Closes
  the Surface Coverage Pass.
- **v0.15.0** (2026-04-28) — *Surface Coverage Pass, phase 5 —
  collaborative edits + clean shutdown.* Knowledge tab gains a
  **Suggestions** sub-page (lists pending / applied / rejected
  suggestions, Accept button with confirmation alert) and the
  long-stubbed `tado_dome_stop` FFI is finally wired to
  `NSApplication.willTerminateNotification` so Cmd+Q triggers a
  clean WAL checkpoint instead of relying on kernel teardown. 2
  new FFI shims (`suggestion_list/apply`); Tools inspector
  deferred to v0.16 (needs a real `tools.list` backing method).
- **v0.14.0** (2026-04-28) — *Surface Coverage Pass, phase 4 —
  browse what the daemon knows.* Knowledge tab gains **Topics**
  and **Packs** sub-pages (authoritative topic listing via
  `topic_list`, full context-pack browser via `context_list` /
  `context_get`); Calendar tab gains a **Daemon** mode that
  renders `calendar_range` entries with kind icons + status
  pills. 5 new FFI shims (`calendar_range`, `topic_list`,
  `graph_links`, `context_list`, `context_get`) + Swift Codable
  bindings.
- **v0.13.0** (2026-04-28) — *Surface Coverage Pass, phase 3 —
  operator setup + teardown.* New **Vault status** card on
  Knowledge → System (doc count, topic count, paths, Open in
  Finder / Snapshot / Bulk import buttons), new **Bulk import
  wizard** (3-step sheet → preview → review with checkboxes +
  filter chips → import), new **Agent tokens** settings tab
  (issue / rotate / revoke with one-time secret display + cap
  picker, destructive `NSAlert` guard rails). 8 new FFI shims
  (`vault_status`, `import_preview`, `import_execute`,
  `token_list/create/rotate/revoke`); `ImportPreviewItem` +
  `import_execute` promoted to `pub` in bt-core.
- **v0.12.0** (2026-04-28) — *Surface Coverage Pass, phase 2 —
  observability.* Knowledge → System surface gains: a **vault
  health** card (every check from `system_health` rendered with
  green/red pills); a **scheduler queue** card (ready / scheduled
  / active counts + stale-lease count); an inline **dome-eval
  runner** (window picker 1h/24h/7d/all + Run button → P@5/R@10/
  nDCG/mean-latency/consumption-rate/row-count tiles, all
  computed in-process via a new `replay_for_vault` lib helper —
  no subprocess); and an **audit log** viewer with a filter-by-
  prefix chip showing the last 200 rows + per-row JSON detail.
  5 new FFI shims (`system_health`, `system_automation_status`,
  `system_runtime_envelope`, `audit_tail`, `eval_replay`),
  `StorePaths.domeIndexDB` accessor, dome-eval graduates to a
  workspace dep of `tado-core`.
- **v0.11.0** (2026-04-28) — *Surface Coverage Pass, phase 1.* Two
  big backend subsystems graduate to Dome tabs: the in-process
  **automation/scheduler** (full CRUD via the new
  `Dome → Automation` surface — schedule, pause/resume, run-now,
  retry, delete, with a unified occurrence ledger across every
  automation) and the Phase 5 **retrieval recipes** (new
  `Dome → Recipes` surface — browse the 3 baked defaults plus
  project-scoped overrides, run them with one click, see the
  `GovernedAnswer` with citations + missing-authority callouts,
  edit per-project templates). 11 new FFI shims, 1 lifted
  surface-helpers file (`SurfaceHelpers.swift`), shared by every
  current and future Dome surface.
- **v0.10.0** (2026-04-27) — *Knowledge Catalog overlay.* Schema
  v22→v24 (entity layer + provenance + retrieval log + pending
  enrichment + retrieval recipes + activation marker), heuristic
  hybrid-search rerank, four tokio enrichment workers, byte-stable
  Rust spawn-pack engine (Phase 4 dual-path with Swift fallback),
  three baked retrieval recipes + governed answers (Phase 5),
  `dome-eval` CLI as 9th workspace crate. Plus a v0.10.1-style
  follow-up that scoped the codebase Ingest button to Project vs
  Global with a one-shot purge for the historical global pollution.
- **v0.9.0** (2026-04-25) — *foundation-v2 bundle.* Cargo workspace
  promoted to eight crates, in-process Dome second brain (bt-core
  fused, 21 migrations, Qwen3-Embedding-0.6B replaces hash-noop),
  extension host with Notifications + Dome + Cross-Run Browser,
  real-time A2A via `/tmp/tado-ipc/events.sock` + `tado-events` CLI,
  `tado-mcp` ported from Node to Rust (zero Node runtimes in the
  bundled `.app`), scoped knowledge (global vs project + includeGlobal
  merge), spawn-time context preamble, Eternal retros mirror to Dome,
  relocatable storage root via `StorageLocationManager`,
  Codex picker default → GPT-5.5. Bundles what was previewed in the
  removed v0.10.0/v0.11.0/v0.12.0/v0.13.0 prereleases.
- **v0.8.0** (2026-04-20) — *Persistence subsystem + event pipeline +
  Eternal auto mode.* Canonical state moves to atomic JSON on disk
  (SwiftData becomes a rebuildable cache); five-scope config
  hierarchy with per-scope file watchers; typed `TadoEvent` bus with
  pluggable deliverers (sound, dock badge, banner, NDJSON,
  notifications history); migration runner with pre-apply tarball
  backups; per-project concurrent Eternal/Dispatch runs; Eternal
  Continuous mode switches to Claude Code's `--permission-mode auto`
  with dual-layer config injection; per-phase model/effort; sidebar
  redesign with project grouping and uptime-per-session.
- **v0.7.0** (2026-04-18) — *Rust + Metal renderer.* SwiftTerm
  removed; every tile renders through a Rust `tado-core` static lib
  driving a Metal pipeline (glyph atlas, ANSI state machine, retina
  awareness, color emoji, wide chars, 15 ANSI palette themes,
  selection/copy, blinking cursor); Dispatch self-improvement loop
  via per-phase retros; Projects redesign (card list, zone-based
  detail view, Teams folded into Projects); design system refresh
  (Plus Jakarta Sans, Ember theme, central `Palette`).
- **v0.6.0** (2026-04-16) — *Dispatch Architect workflow + model
  selection + theming.* New "Dispatch" button per project opens a
  markdown brief modal; accepting spawns an architect that designs
  a multi-phase plan, creates per-phase skills via `/skill-creator`,
  writes JSON plan files to `.tado/dispatch/`, and auto-chains phase
  handoffs via `tado-deploy`. Settings gain Claude/Codex model
  pickers (flags pass through to every spawned process). 15 curated
  per-tile color themes.
- **v0.5.0** (2026-04-14) — *`tado-deploy` + multiline input.*
  Agents can spawn new agent sessions on the canvas
  (`tado-deploy "<prompt>" --agent <name>`); smart engine
  resolution from agent definition path; SpawnRequest IPC; Cmd+Enter
  submit so newlines work in the multiline input; bracketed-paste
  for multi-line messages; todo rename / mark-done / trash via
  context menu.
- **v0.4.0** (2026-04-13) — *Node `tado-mcp` server + pub/sub topics
  + team-aware IPC.* TypeScript MCP server exposing the A2A tools
  to any MCP-compatible agent (auto-registered in `~/.claude.json`);
  pub/sub via `tado-publish` / `tado-subscribe` / `tado-topics`;
  broadcast filterable by `--project` / `--team`; rich
  `TADO_*` env vars on every spawn; one-click bootstrap injecting
  Tado A2A docs into a project's `CLAUDE.md` / `AGENTS.md`. (This
  Node tree is now superseded by the v0.9.0 Rust port.)
- **v0.3.0** (2026-04-12) — *Projects + Teams.* Todos organized under
  a project (working directory + auto-discovered agents from
  `.claude/agents/` and `.codex/agents/`); teams group agents within
  a project; project detail view with teams/agents/todos tree; page
  navigation bar replaces the old view-mode toggle; per-project
  working directory inherited by spawned processes.
- **v0.2.0** (2026-04-12) — *Done/Trash lists + tile manipulation +
  initial A2A.* Cmd+D for done, Cmd+T for trash; resizable +
  movable tiles via drag handles + title bar; first A2A surface
  (`tado-read` command) for reading terminal output; Claude Code
  permission mode + thinking effort settings; Codex approval mode
  + reasoning effort; mode/effort flags forwarded to spawned
  processes.
- **v0.1.0** (2026-04-12) — *Tado v1: todo → terminal.* Todo-driven
  terminal spawning with Claude Code + Codex engine support;
  pannable/zoomable canvas with draggable tiles; prompt queueing
  with auto-send on idle detection; basic IPC (`tado-send`,
  `tado-recv`, `tado-list`); forward mode; SwiftData persistence;
  sidebar with live status; engine + grid settings.

**Historical tag**: `v1.0.0-rust-metal` is a squash tag from the
original Rust+Metal rewrite (now superseded by the released versions
above; kept for archaeology — no GitHub release exists).
