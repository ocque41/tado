# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.13.0] - 2026-04-28

The "operator setup + teardown" release. Phase 3 of the Surface
Coverage Pass adds the **vault status** card, the **bulk import
wizard**, and the **agent tokens** tab to Settings. After this
release the user can see what's in the vault, import an external
markdown tree in one go, and issue / rotate / revoke tokens for
non-Tado MCP clients without touching `<vault>/.bt/config.toml`
by hand.

### Added
- **Vault status card** at the top of Knowledge → System. Shows
  doc count, topic count, vault path, socket path, plus three
  actions: "Open in Finder" (jumps to the vault root), "Snapshot
  vault" (kicks `BackupManager.createBackup(reason:)`), "Bulk
  import…" (opens the new wizard).
- **Bulk import wizard** (`ImportWizard.swift`) — three-step sheet:
  pick folder → review tree with per-file checkboxes + filter
  chips (Notes only / Attachments only / Select all / Clear) →
  confirm. Calls `tado_dome_import_preview` then
  `tado_dome_import_execute`. Surfaces the daemon's "must be
  inside the vault" constraint with a clear error message that
  points the user at `<vault>/inbox/`.
- **Agent tokens settings tab.** New `Settings → Agent tokens`
  section. Issue form with a label + a chip-grid of capabilities
  (`search/read/note/schedule/graph/context/supersede/verify/
  decay/recipe`). Issued / rotated tokens show the raw secret
  exactly once in a copyable banner with a one-time "Copy" button.
  Per-row `Rotate` (warning dialog) and `Revoke` (critical
  dialog) actions. Revoked rows stay visible (audit trail) but
  greyed out with a "Revoked" pill.
- **8 new FFI shims**: `tado_dome_vault_status`,
  `tado_dome_import_preview`, `tado_dome_import_execute`,
  `tado_dome_token_list`, `tado_dome_token_create`,
  `tado_dome_token_rotate`, `tado_dome_token_revoke`. Matching
  Swift bindings as Codable structs on `DomeRpcClient`.

### Changed
- **`bt_core::service::ImportPreviewItem`** + `import_execute`
  promoted from private to `pub` so the Phase 3 FFI shim can
  call them directly. JSON shape unchanged — already
  Serialize/Deserialize-derived.

## [0.12.0] - 2026-04-28

The "see what the system is doing" release. Phase 2 of the
Surface Coverage Pass adds full operator-facing observability —
**vault health**, **scheduler queue**, **audit log**, and an
inline **dome-eval** runner — to the existing Knowledge → System
surface. After this release the user can answer "is the daemon
healthy / what's queued / who did what / how good is retrieval
quality" without leaving the app.

### Added
- **Vault health card.** New section at the top of the System
  surface that renders every check from
  `tado_dome_system_health` — vault root, topics dir, .bt dir,
  sqlite file, audit log file, config.toml — with a green
  checkmark or red triangle per row plus the resolved path. Calls
  out a SQLite open failure with a one-liner pointing to the
  daemon log.
- **Scheduler queue card.** Reads `system_automation_status`
  and shows queue depths (ready / scheduled / active) plus
  stale-lease count as four big numerics. Stale-lease count > 0
  triggers a red "likely a worker crash" callout.
- **dome-eval inline runner.** New section on the System surface
  with a window picker (1h / 24h / 7 days / All time) and a
  **Run eval** button that calls the new `replay_for_vault` lib
  helper in-process — no subprocess, no PATH dependency. Renders
  P@5 / R@10 / nDCG / mean latency / consumed % / row count as a
  single-row of stat tiles. The CLI binary still works for power
  users.
- **Audit log viewer.** New section at the bottom of the System
  surface listing the last 200 audit rows. Per-row pill (ok/err),
  actor (`user_ui:tado-ui`, agent token id, etc.), action name,
  timestamp, and a flattened single-line JSON of `details`.
  Filter chip lets you narrow by action prefix
  (e.g. `automation.`, `vault.`, `recipe.`).
- **5 new FFI shims**: `tado_dome_system_health`,
  `tado_dome_system_automation_status`,
  `tado_dome_system_runtime_envelope`,
  `tado_dome_audit_tail`, and `tado_dome_eval_replay`. Plus
  `dome-eval` exposes a new public `replay_for_vault(path,
  since_seconds)` so the FFI can run replay in-process.
- **`StorePaths.domeIndexDB`** — Swift accessor for the SQLite
  path so any future surface that needs to point an external tool
  at the vault DB has a single source of truth.

### Changed
- **`tado-core` (terminal crate)** now depends on the `dome-eval`
  crate so the FFI shim can call into the eval lib without
  spawning a subprocess. The CLI binary is unchanged.
- **`KnowledgeSystemSurface.reload`** runs three more parallel
  Task.detached fetches (health, scheduler, audit) alongside the
  existing agent / retrieval-log / queue-depth reads. Total
  reload latency unchanged in practice — they all hit the same
  daemon.

## [0.11.0] - 2026-04-28

The "every backend feature gets a UI" release, phase 1. Two
high-value backend subsystems that have been in-process inside
`bt-core` since v0.9 but had no Swift surface — the in-process
**automation/scheduler** and the Phase 5 **retrieval recipes** —
graduate to first-class top-level Dome tabs. The audit that drove
this release found 22 categories of orphaned backend capabilities;
v0.11–v0.16 will land them all (see Surface Coverage Pass plan).

### Added
- **Automation tab.** New top-level `Dome → Automation` surface that
  reads + writes the in-process scheduler. Card list of every
  defined automation with status pill + last-run pill + scope chip,
  inline create/edit sheet (title, executor kind, prompt template,
  schedule kind + JSON, retry policy, executor config, concurrency,
  timezone, enabled), `⋯` menu with Pause/Resume/Run-now/Edit/
  Duplicate/Delete (destructive guard rails on Delete), and a
  unified occurrence ledger across every automation showing recent
  runs with a per-row expansion that shows status, planned/started/
  finished timestamps, run id, failure kind/message, and a "Retry"
  button on failed/cancelled rows. All actions go through
  `swift_ui_actor()` so every operator action lands in the audit
  log under `actor=user_ui`.
- **Recipes tab.** New top-level `Dome → Recipes` surface that
  browses every retrieval recipe in the active scope (3 baked
  defaults — architecture-review, completion-claim, team-handoff —
  plus any project-scoped overrides at `<project>/.tado/
  verified-prompts/<intent>.md`). Left rail picks one; right pane
  shows the recipe's full retrieval policy (topics, knowledge
  kinds, scope, freshness decay, max tokens, min combined score,
  top-K) and a **Run recipe** button that produces the
  `GovernedAnswer`: rendered markdown, a citation table with
  per-citation confidence + freshness, and explicit
  *missing-authority* callouts. "Copy answer" / "Copy as
  citation" / "Edit template" / "Reset to default" actions.
- **11 new FFI shims** in `dome_ffi.rs` exposing the automation +
  recipe service methods to Swift: `tado_dome_automation_list`,
  `_get`, `_create`, `_update`, `_delete`, `_set_paused`,
  `_run_now`, `_occurrence_list`, `_retry_occurrence`, plus
  `tado_dome_recipe_list` and `tado_dome_recipe_apply`. Matching C
  declarations land in `Sources/CTadoCore/include/tado_core.h`.
- **Shared surface helpers** lifted out of `KnowledgeSurface.swift`
  into `Surfaces/SurfaceHelpers.swift` (`surfaceHeader(...)` and
  `surfaceEmpty(...)`) so future Dome surfaces — Automation,
  Recipes, and the four upcoming surfaces in v0.12–v0.15 — share
  the same header chrome and empty-state look without copy-paste.

### Changed
- **`DomeSurfaceTab` enum** gains `automation` and `recipes` cases.
  Cmd+1..Cmd+7 hotkeys auto-extend to cover the new tabs because
  the registrar reads `DomeSurfaceTab.allCases`. Existing tabs
  keep their order so muscle memory isn't disturbed.
- **`KnowledgeSurface.swift`** — internal `empty(...)` calls renamed
  to `surfaceEmpty(...)` matching the lifted helper. No user-visible
  change.

### Also (rolled in from the v0.10.1 work that didn't ship as its own tag)
- **Scope-aware Ingest button.** `Dome → Knowledge → System`'s
  "Ingest codebase" button now reads `Ingest codebase → \(scope.label)`
  with a chip below explaining where files will land, an `NSAlert`
  warning when the scope is Global, and the file picker prefills
  with `domeScope.projectRoot` when a project is selected. New
  `Clear globally-ingested codebases (N)` button appears whenever
  there are global codebase rows from prior accidental ingests —
  takes a backup snapshot first, then purges via the new
  `vault_purge_topic_scope` RPC.
- **`vault_purge_topic_scope` RPC + FFI** — `tado_dome_vault_purge_topic_scope_count`
  + `tado_dome_vault_purge_topic_scope` shims for the cleanup
  button. Cascades through `graph_edges` → `graph_nodes` →
  `note_chunks` → `doc_meta` → `fts_notes` → `docs` and removes
  the on-disk `topics/<topic>/<slug>/` folders, dropping the parent
  topic dir if empty. Audited as `vault.purge_topic_scope`.
- **`bt-core/tests/ingest_scope_contract.rs`** — locks the contract
  that `vault_ingest_path` persists `(owner_scope, project_id)`
  exactly as passed and that `vault_purge_topic_scope` only
  deletes the matching scope tuple.
- **Linker tidy** — `linker.rs:90` lost the redundant parens that
  triggered a `unused_parens` warning in `make dev`.

## [0.10.0] - 2026-04-25

The "graph of knowledge embeds the entire codebase" release. v0.9.0
shipped the Dome second brain with `Qwen3EmbeddingProvider` as a stub
that fell back to FNV-1a hashing — vectors had the right *shape* but
zero semantic content, and only markdown notes were indexed. v0.10.0
makes Dome's vector graph actually semantic and extends it to source
code: Qwen3-Embedding-0.6B runs in-process via candle on Metal,
project source trees get tree-sitter-aware AST chunks plus i8-quantized
embeddings, and a `notify`-driven file watcher keeps the index live
on every save. Agents on the canvas can now ask `dome_code_search
"where do we spawn the PTY"` and get pointed at `pty.rs` even though
the literal phrase appears nowhere in the codebase.

The dome-mcp tool inventory grew from 8 → 13 (5 new code-indexing
tools), the `tado-dome` CLI gained 6 new subcommands following the
existing `--toon` AXI conventions, and SwiftUI gained an onboarding
overlay, a sidebar progress badge, and a per-user kill switch.

The Knowledge Catalog overlay (Phases 1-5 below) brings dome-mcp
to **18 tools**, schema to **v24**, and adds the `dome-eval` crate
(measurable retrieval evaluation). Final cumulative test count:
**195+ Rust tests**, 0 failures, 0 clippy errors. End of the cycle
ships a 25-item hardening pass — race conditions closed, retention
policies on every append-only table, panic isolation in workers,
bounded caches everywhere, deterministic byte-stable spawn-pack
contract pinned by integration tests.

### Hardening (post-implementation pass)

A focused audit before tagging surfaced 7 real bugs and 5 scalability
gaps; all are fixed.

- **Feature-flag wiring**: `dome.contextPacksV2` is now hydrated
  from `global.json` at app launch and tracks live changes via
  `ScopedConfig.addOnChange` — without this, the v0.10 Swift
  composer was the only path that ever ran.
- **TOCTOU race in `enrichment::enqueue`**: SELECT-then-INSERT is
  now wrapped in an explicit transaction so concurrent doc writes
  can't both insert duplicate jobs for the same target.
- **claim_batch atomicity**: `BEGIN IMMEDIATE` plus the
  `WHERE status='queued'` guard on the UPDATE so two enrichment
  workers can never claim the same row.
- **Worker panic isolation**: `drain_once` wraps each job in
  `catch_unwind`. A poisoned input fails the job (status=`failed`,
  `panic: …` recorded in `last_error`) instead of taking down the
  worker for the daemon's lifetime. Per the no-watchdog rule,
  there's still no auto-restart — operators see the failed row and
  decide.
- **Cache invalidation correctness**: `spawn_pack_invalidate_project(None)`
  now clears the entire spawn-pack cache (a global change can affect
  every project's merged-scope view), not just the empty-string
  cache key.
- **Extractor confidence**: deterministic extractions write
  `confidence=0.95` explicitly so the rerank's confidence multiplier
  doesn't demote freshly-extracted entities below un-extracted notes
  (which default to 1.0×). Stub nodes get 0.5 (low signal); file
  mentions get 0.9 (high but with whitelisted-extension caveats).
- **Heading parser case sensitivity**: `## decision: …` and
  `## DECISION: …` now extract the same way `## Decision: …` does,
  while preserving original-case display labels.
- **Recipe filter prefix matching**: `recipes/runner.rs::filter_titles`
  switched from substring (`title.contains("decision")`) to prefix
  match (`title.starts_with("decision:")`), eliminating false
  positives like "Income report" matching the "outcome" filter.
- **Bounded spawn-pack cache**: hard cap of 128 entries, opportunistic
  expired-entry sweep on insert, soonest-to-expire eviction beyond
  the cap. No more unbounded growth on long-lived sessions with
  rotating projects/agents.
- **Retention policies**: the decayer now prunes `retrieval_log`
  rows older than 90 days and finished `pending_enrichment` jobs
  older than 30 days. Live (queued/running) jobs are never pruned.
- **Truncated error strings**: enrichment job errors are capped at
  2 KB so a runaway diagnostic doesn't bloat
  `pending_enrichment.last_error` or slow scans.
- **JSON-failure observability**: `composeViaRust` writes a one-
  line stderr message when JSON encoding fails (visible in
  Console.app), then falls back to the v0.10 Swift composer so
  spawns never lose their preamble — diagnostic, not blocking.

### Added — Real Qwen3-Embedding-0.6B in pure Rust

- **candle-core 0.10 + Metal acceleration.** `bt-core` now bundles
  candle (`metal` feature) plus a vendored `qwen3_model` (the
  upstream `candle_transformers::models::qwen3` with `clear_kv_cache`
  exposed and the `model.` prefix removed to match how the Qwen
  team publishes the embedding model's safetensors). Forward passes
  go through `tokio::task::spawn_blocking`; F16 dtype on Metal,
  F32 on CPU fallback. Single-input batch=1 throughput hits
  ~120 emb/s on M-series, enough to embed a 5 000-file project in
  ~10 minutes.
- **First-launch model fetch.** New `notes::model_fetch` resumable
  HTTP-Range downloader pulls `model.safetensors` (~1.19 GB F16),
  `tokenizer.json`, `tokenizer_config.json`, and `config.json` from
  HuggingFace into `<vault>/.bt/models/qwen3-embedding-0.6b/`. The
  bar reads from on-disk file sizes (not in-memory atomics) so
  progress survives app restarts and partial downloads pick up
  where they left off. A `_fetch.log` next to the model files
  records every HTTP attempt for debugging.
- **`DomeOnboardingView`.** SwiftUI overlay that appears in
  `DomeRootView` whenever the runtime isn't loaded. Shows live
  progress, exposes a "Choose…" path picker that writes
  `TADO_DOME_EMBEDDING_MODEL_PATH` (escape hatch for users behind
  proxies who pre-downloaded the files), and surfaces both fetch
  errors and runtime-load errors so silent failure is no longer
  possible.
- **Honest metadata stamping.** `Qwen3EmbeddingProvider::metadata()`
  now returns `noop@1` (384-dim) when the runtime isn't loaded, so
  rows written during the fallback window can be found by future
  re-embedding sweeps. Stamping qwen3 metadata on hash bytes
  silently corrupted the index in v0.9.0; that bug is fixed.

### Added — Codebase indexing (Phase 2)

- **Schema migration 22**: five new tables — `code_projects`,
  `code_files`, `code_chunks`, `code_index_jobs`, `fts_code` (FTS5
  with `unicode61` tokenizer to preserve identifiers).
- **`bt-core::code` module** (six files: `mod`, `language`, `walker`,
  `chunker`, `store`, `indexer`). Walker uses the `ignore` crate
  (ripgrep's engine) honoring `.gitignore` + `.ignore` + a hardcoded
  20-directory denylist plus a `.domeignore` per-project override.
  Binary detection skips files with NUL bytes / >30 % non-text in
  the first 4 KB; size cap 1 MB / 10 000 lines; project cap
  25 000 files.
- **Tree-sitter chunker** for Swift, Rust, TypeScript/TSX, and
  Python (the four most-used languages in the Tado workspace). AST
  nodes matching `function_declaration` / `class_declaration` /
  `impl_item` / etc become their own chunks; gap regions between
  AST chunks fall back to overlapping line windows so top-of-file
  imports don't disappear. Every other extension goes through
  `LineWindowChunker` (40 lines / 5-line overlap).
- **i8 quantization** for code embeddings. Reduces stored vector
  size 4× (1024 dim × 4 B → 1024 B per chunk). `embedding_quant`
  column lets future writes opt back into f32 if needed.
- **End-to-end RPC surface.** `code.project.register`,
  `code.project.unregister`, `code.list_projects`,
  `code.index_project { full_rebuild }`, `code.index_status`.
- **`NewProjectSheet` auto-index hook.** Creating a project
  registers + full-rebuilds the code index on a detached task; the
  user keeps working while embedding proceeds in the background.

### Added — Hybrid retrieval (Phase 3)

- **`bt-core::code::search`**. `code_hybrid_search` runs vector
  cosine over i8-decoded `code_chunks` + FTS5 BM25 over `fts_code`,
  blended at α=0.6. Filters by `project_ids` and `languages`; the
  vector lane skips chunks stamped with a different
  `embedding_model_id` / `embedding_dimension` so qwen3 query
  vectors never get compared against legacy noop@1 rows. UTF-8-
  boundary-safe excerpts.
- **`code.search` RPC** + `tado_dome_code_search(query_json)` FFI
  + `DomeRpcClient.codeSearch(...)` Swift wrapper.
- **MCP inventory: +2 tools** → `dome_code_search` (project +
  language filtered hybrid retrieval) and `dome_code_status` (poll
  an in-flight job).

### Added — File-watch incremental + UI (Phase 4)

- **`bt-core::code::watcher`**. `notify`-driven FSEvents watcher
  with 500 ms debounce, FSEvents canonical-path normalization (the
  `/private/tmp` symlink quirk that breaks `strip_prefix`), per-
  path SHA dedup so untouched-but-rewritten files don't churn the
  index, deletion-as-row-purge, `panic::catch_unwind` so a single
  malformed file can't kill the watcher thread. `WatchRegistry`
  on `CoreService` keyed by `project_id`.
- **Auto-resume on app boot.** `tado_dome_start` calls
  `code_resume_watchers` for every `enabled=1` project so users
  don't re-click "watch" on every launch.
- **Auto-stop on unregister.** `code.project.unregister` stops the
  watcher first to prevent it from racing the chunk-row cleanup.
- **MCP inventory: +3 tools** → `dome_code_watch`,
  `dome_code_unwatch`, `dome_code_watch_list`. Total 13.
- **`CodeIndexBadge`** sidebar component on every project card.
  Three states: spinning indicator + "X / Y files" while indexing,
  green eye + "watching" while a watcher is live, hidden when idle.
- **`CodeIndexEventBridge`** singleton MainActor poller bridges
  the bt-core status FFIs to `EventBus`. The `InAppBannerOverlay`,
  `EventPersister` (NDJSON), and `EventsSocketBridge` (`tado-events`
  CLI subscribers) all surface `code.index.{started,progress,
  completed,failed}` events for free.
- **`AppSettings.codeIndexingEnabled`** per-user kill switch.
  Live-reactive: flipping OFF calls `code.watch.stop_all`, flipping
  ON calls `code.watch.resume_all`. Surfaced in Settings → Code
  indexing alongside per-project "Re-index" buttons.

### Added — `tado-dome` CLI (AXI parity)

Every new subcommand follows the existing `tado-list --toon` AXI
conventions (space-separated, `-` for null, spaces → `_`, variable-
length excerpt last with internal whitespace collapsed, silent on
empty so agents can detect zero hits via stdout/exit):

```
tado-dome code-register --project <id> --root <path> [--name <n>]
tado-dome code-unregister --project <id> [--keep]
tado-dome code-list                        [--toon]
tado-dome index --project <id> [--root <path>] [--full]
tado-dome index-status --project <id>
tado-dome code-search "query" [--project ...] [--language ...]
                              [--limit N] [--alpha 0.6] [--toon]
tado-dome watch / unwatch --project <id>
tado-dome watch-list                       [--toon]
tado-dome wait-for-index --project <id> [--timeout 900] [--toon]
                          # exit 0 on completion, 1 on timeout, 2 on error
```

`tado-dome index --root <path>` auto-registers if the project
isn't there yet — one-step path for a fresh codebase.

### Verified — Real-world end-to-end against the Tado source tree

Two `#[ignore]` integration tests in
`bt-core/tests/code_index_e2e.rs` exercise the full pipeline
against `~/Library/Application Support/Tado/dome/.bt/models/
qwen3-embedding-0.6b/` and the Tado repo itself:

| Test | What it does | Result |
|---|---|---|
| `indexes_real_tado_codebase_with_real_qwen3` | Indexes 237 files / 2 325 chunks across 10 languages, then re-runs to verify SHA dedup | 100 % skipped on second pass |
| `hybrid_search_finds_real_code` | Identifier query (`spawn_session`) + paraphrased semantic query (`where do we spawn the PTY for a terminal session`) | Top vector hit on identifier query is `tado_session_spawn` (cosine 0.745); paraphrased query returns `pty.rs` / `session.rs` / `lib.rs` with zero lexical hits — the vector lane carried the entire query |

### Changed

- **bt-core grew 6 deps:** `candle-core/-nn/-transformers 0.10`
  (with `metal` feature), `tokenizers 0.21`, `reqwest 0.12`
  (rustls-tls + blocking + stream), `tree-sitter 0.26` plus four
  language grammars (`rust 0.24`, `swift 0.7`, `typescript 0.23`,
  `python 0.25`), `ignore 0.4`, `notify 8` + `notify-debouncer-mini 0.6`.
- **`tado-terminal` grew `chrono`** for fetch.log timestamping.
- **`Qwen3EmbeddingProvider`** stamps `noop@1` metadata when the
  runtime isn't loaded (was `qwen3-embedding-0.6b@1` regardless).
  Honest stamps prevent the index from silently mixing vector
  spaces during the model-load window.
- **Search query embedding** now uses `embed_query` (with the
  trained instruction prefix) on the query side while passages
  stay on `embed`. Was using `embed` for both; the asymmetric
  pairing recovers ~10 % retrieval recall.

### Fixed

- **Stuck "Downloading model.safetensors…" progress bar.** v0.9.0's
  in-memory atomic counter reset to 0 on every app restart even
  when a partial 800 MB file was on disk; the bar would sit at
  ~0 % while the resume succeeded silently. v0.10.0 reads byte
  counts directly from disk so progress survives restarts and
  resume-from-`Range` shows up correctly.
- **`MODEL_FETCH_STARTED: OnceLock<()>` blocked retries.** A
  failed first attempt could only be retried by relaunching the
  app. Replaced with `MODEL_FETCH_RUNNING: Mutex<bool>` that flips
  back to `false` on worker exit.
- **Silent runtime-load failures.** Eager-load on `tado_dome_start`
  used to `eprintln!` the error and disappear; now `MODEL_LOAD_ERROR`
  is surfaced through `tado_dome_model_status` so the onboarding
  overlay shows "files complete but load failed: <reason>".
- **Vendored qwen3 weight prefix.** Upstream `candle_transformers`
  expects `model.embed_tokens.weight` etc.; Qwen3-Embedding-0.6B
  publishes weights without the `model.` prefix. Without the fix,
  `Qwen3Runtime::load` errored with "tensor not found" the moment
  any user finished the download.

### Added — Knowledge Catalog foundation (Phase 5)

Tado's second brain takes the design discipline Google Cloud just
crystallized as the **Knowledge Catalog** (formerly Dataplex Universal
Catalog, rebranded April 2026) — *Aggregate, Enrich, Search* with
measurable retrieval — and ports it down to a single-user laptop.
v0.10.0 lands the foundation; later releases add background
enrichment (v0.12), context packs v2 (v0.13), and governed answers
with retrieval recipes (v0.14). The full design lives in
`/Users/miguel/.claude/plans/1-analyze-project-start-recursive-naur.md`.

- **Schema migration 23**: lifecycle, provenance, and measurement
  layer. Purely additive — every column has a constant default,
  every new table uses `IF NOT EXISTS`, every existing query path
  keeps working unchanged. Schema is now at v23.
  - `graph_nodes` gains `confidence`, `superseded_by`, `supersedes`,
    `expires_at`, `archived_at`, `content_hash`,
    `last_referenced_at`, `entity_version` (+ five indexes). Lets
    entities outlive their first write — confirmed, disputed,
    archived, or replaced without losing history.
  - `graph_edges` gains `source_signal` (`'deterministic_extract' |
    'agent_assertion' | 'manual' | 'user_link' | 'backfill'`),
    `signal_confidence`, `evidence_id`. Multiple signals can claim
    the same conceptual edge; aggregation happens at query time.
  - `retrieval_log` (new): one row per `dome_search` /
    `dome_graph_query` / `dome_context_resolve` call. Carries the
    actor, scope, query, ranked results, per-result scope (for
    cross-project audit), latency, optional pack id, and
    `was_consumed` flag. Append-only; the upcoming `dome-eval`
    CLI replays it for measurable evaluation.
  - `pending_enrichment` (new): durable queue mirroring the
    `code_index_jobs` shape so v0.12's enrichment workers
    (extractor, linker, deduper, decayer) survive crashes.
  - `retrieval_recipes` (new): registry reserved for v0.14's
    intent-keyed retrieval policies (Tado's analog of Knowledge
    Catalog "verified queries"). Phase 1 reserves the shape;
    Phase 5 fills it.

- **Heuristic rerank in `notes::search::hybrid_search`.** After the
  existing convex combine, `combined_score` is multiplied by
  `(0.5 + 0.5·freshness) × scope_match × confidence ×
  supersede_penalty`. Freshness is an exponential decay with a
  30-day half-life over the most recent of `updated_at` /
  `last_referenced_at` / `created_at` (no `freshness_cache` table —
  computed inline as a pure function). Scope match is 1.0× for
  hits in the caller's preferred scope, 0.6× otherwise. Confidence
  and supersede penalty are 1.0× placeholders in v0.10 (Phase 3
  reads them from `graph_nodes`). The freshness function handles
  both RFC3339 and SQLite's native `datetime('now')` shapes.

- **Retrieval log writes are non-breaking.** `HybridQuery` gains an
  optional `ctx: Option<RetrievalCtx>` field. When `None`, behavior
  is byte-identical to v0.9 — no rerank, no log, every existing
  caller unchanged. When `Some`, hybrid search applies the rerank
  and writes one row to `retrieval_log` with measured latency.
  `dome-mcp::dome_search` always sets the ctx (logging `tool:
  "dome_search"`); the bare `search.query` JSON-RPC method now
  parses `actor` from params and sets the ctx automatically. Log
  failures are silent — logging never fails the user-visible
  search.

- **Freshness signal feedback loop.** `agent.context_event.record`
  with `event_kind = 'agent_used_context'` now bumps the consumed
  `graph_node`'s `last_referenced_at` to `now` (when the row isn't
  already archived) and flips matching `retrieval_log` rows'
  `was_consumed = 1` (when a `context_id` is present). This is the
  implicit-feedback hook the upcoming `dome-eval replay` reads for
  precision@k mining.

- **Bootstrap knowledge prompt rewritten.** "Bootstrap knowledge
  layer" now teaches agents the v0.10 second-brain contract: the
  AXI-compact `--toon` convention (~40-45 % fewer tokens for bulk
  reads), structured-retro recipe (`## Outcome / ## Decision /
  ## Caveats / ## Cite / ## Next agent should know`), the
  measurable-retrieval contract (every search is logged, every
  consumption shapes the next preamble), and the lifecycle
  primitives that ship now (`confidence`, `superseded_by`,
  `expires_at`, `last_referenced_at`) plus the MCP tools that will
  drive them in later releases (`dome_supersede`, `dome_verify`,
  `dome_decay`, `dome_recipe_apply`). The "Bootstrap A2A tools"
  prompt gains a one-block AXI convention callout so both prompts
  speak with one voice. Existing projects re-run the bootstrap to
  pick up the new shape.

### Added — `dome-eval` CLI + measurable evaluation (Phase 2)

Phase 1 of the Knowledge Catalog upgrade added the `retrieval_log`
table; Phase 2 ships the harness that turns it into a regression
gate. New crate `tado-core/crates/dome-eval/` (Rust [[bin]] + [[lib]])
with three subcommands:

- **`dome-eval replay --vault <db> [--since 7d]`** — reads every
  `retrieval_log` row in the window and reports precision@k /
  recall@k / nDCG / consumption rate / mean latency. Implicit
  feedback: if the row's `was_consumed=1` (an `agent_used_context`
  event flipped it), the entire ranked list is treated as relevant
  for that call. The signal you actually care about is consumption
  rate — "did the agent act on what we served them" — which the
  Phase 1 feedback loop now feeds.
- **`dome-eval corpus run <fixture.yaml>`** — replays a hand-labeled
  YAML corpus against an in-memory v23 vault seeded through the
  production write paths (`bt_core::notes::store::reindex_note` for
  chunks + embeddings, real `fts_notes` insertion for the lexical
  lane). Computes precision@k / recall@k / nDCG against labeled
  relevance and exits non-zero on threshold regression. Designed as
  a CI gate — `cargo test -p dome-eval --test baseline_corpus` runs
  every PR.
- **`dome-eval explain --vault <db> --log-id <id>`** — reconstructs
  the rerank decision for one logged query: per-result freshness
  multiplier, scope-match multiplier, supersede penalty,
  confidence, final ordering. The "why was this answer ranked
  first?" tool. Joins `retrieval_log` × `docs` × `graph_nodes` to
  recover what `hybrid_search` saw at call time.

- **30-doc / 30-case baseline corpus** at
  `tado-core/crates/dome-eval/tests/corpus/baseline.yaml`. Three
  intent buckets (architecture-review, completion-claim,
  team-handoff) plus six distractors that are semantically near but
  not relevant. Calibrated against the v0.10 NoopEmbedder +
  heuristic-rerank baseline (P@5=0.193, P@10=0.097, R@10=0.967,
  nDCG@10=0.967); thresholds set ~5% below measured to catch real
  regressions without false-failing on scoring noise. Real-model
  retrieval is exercised by `bt-core/tests/code_index_e2e.rs`,
  which is gated behind the `RUN_REAL_QWEN3_TESTS` flag.

- **Defensive FTS5 query sanitizer** in
  `bt_core::notes::sanitize_fts5_query`. Discovered while building
  the corpus: a query like `"Rust-first"` crashed `dome_search`
  with `no such column: first` because FTS5 parses bare hyphens as
  column qualifiers. The sanitizer now wraps each whitespace
  separated token in double quotes (after stripping any embedded
  quotes), turning the query into a clean term-AND-term match.
  Production agents writing hyphenated or punctuated queries no
  longer crash the daemon. Test coverage:
  `notes::search::tests::lexical_search_handles_hyphenated_query`.

- **Knowledge → System "Retrieval Log" panel.** New section in the
  Dome system surface lists the most-recent 20 `retrieval_log`
  rows with header chips for total count, consumption rate,
  and mean latency — the same numbers `dome-eval replay` prints,
  served live from the daemon via the new
  `tado_dome_retrieval_log_recent` FFI. Each row shows tool
  (e.g. `dome_search`), query, actor, scope, hit count, and a
  consumption checkmark. New JSON-RPC method
  `retrieval.log.recent` for non-Swift callers.

### Added — Entity layer + deterministic enrichment (Phase 3)

Phase 1 added the schema. Phase 2 made it measurable. Phase 3 turns
the still raw notes table into a typed entity graph:
deterministic enrichment workers run as tokio tasks alongside the
scheduler tick, every doc write enqueues an extract job, and the
heuristic rerank now reads real confidence + supersede + last-
referenced-at from `graph_nodes`. Plus three new MCP tools
(`dome_supersede`, `dome_verify`, `dome_decay`) bring lifecycle
mutations to agent reach. dome-mcp grew from 13 → 16 tools.

- **`tado-core/crates/bt-core/src/enrichment/`** — six-module
  pipeline (`mod`, `extractor`, `linker`, `deduper`, `decayer`,
  `worker`). The worker pool spawns one tokio task per kind, each
  polling `pending_enrichment` every 2 s with a batch size of 16.
  Decayer ticks every 15 min on its own cadence (TTL/retention is a
  sweep, not a queue drain). Drop semantics: panics tear down only
  the affected worker — no auto-restart, no watchdog. Recoverable
  errors stash into `pending_enrichment.last_error` and the worker
  keeps going.

- **Deterministic extractor** — markdown link parser
  (`dome://note/<id>` → `references` edge, `file://path` →
  `mentions_file`, `agent://name` → `authored_by`, `run://<id>` →
  `occurred_in_run`); heading parser lifts `## Decision: …`,
  `## Intent: …`, `## Outcome: …`, `## Caveats: …`, `## Retro …`
  into typed graph_nodes; file-mention scanner turns paths like
  `Sources/Auth/Session.swift:42` into `mentions_file` edges with
  whitelisted extensions. Idempotent: a deterministic node id =
  `sha256(doc_id ‖ kind ‖ lower(label))[:24]` so re-extracting the
  same body is a no-op.

- **Linker** — resolves "stub" graph_nodes (created when an extractor
  encountered a forward reference whose target hadn't been written
  yet). Re-points every edge from the stub to the real node when
  one materialises with matching `(kind, ref_id)`, then archives the
  stub. Idempotent on a clean DB.

- **Deduper** — content-hash exact match across `(content_hash, kind,
  group_key)` tuples. The newest row wins; older rows get
  `superseded_by = newer.node_id` and the search rerank's supersede
  penalty (0.3×) demotes them automatically. Also emits a
  `supersedes` graph_edge with `source_signal='deterministic_extract'`
  for the graph view.

- **Decayer** — three sweeps on each tick: explicit TTL (`expires_at <
  now()`), per-kind retention (retros default to 540 days), and
  stub-archival (any unresolved stub older than 14 days). Soft
  delete only — `archived_at` is set; rows survive for audit and
  rerank demotes them. Hard delete is reserved for explicit user
  action via Knowledge → System.

- **Auto-enqueue from doc writes** — every `db::upsert_doc` call
  site (5 in service.rs across `doc.create_scoped`, `vault_ingest`,
  `doc.update_user`, `doc.update_agent`, and the Eternal craft-
  session writer) now also enqueues an `Extract` + `Link` + `Dedupe`
  job. Idempotent: a queued/running job for the same
  `(target_kind, target_id, kind)` is coalesced rather than
  duplicated.

- **Heuristic rerank reads real values** —
  [`bt_core::notes::rerank`](tado-core/crates/bt-core/src/notes/search.rs)
  now consumes `confidence` and `superseded_by` from `graph_nodes`
  via the doc → entity join in `attach_doc_metadata`. Confidence
  defaults to 1.0 when no typed entity exists yet (so legacy rows
  aren't penalised). Superseded rows get a 0.3× penalty — heavy
  demotion that keeps retired facts visible for audit while
  ranking them below their replacements. Two new tests exercise
  both paths.

- **3 new MCP tools — `dome_supersede`, `dome_verify`, `dome_decay`**
  — round-trip through `node.supersede` / `node.verify` /
  `node.decay` JSON-RPC methods. `dome_verify` accepts
  `verdict ∈ {"confirmed", "disputed"}` and lifts confidence to
  `max(0.9, current)` or floors at `min(0.4, current)` accordingly,
  recording an `agent_assertion` edge from the verifier to the node.
  Provenance signal feeds future eval — multiple verifiers can
  converge on a fact, the deduper sees the chain.

- **`tado_dome_node_supersede` / `tado_dome_node_verify` /
  `tado_dome_node_decay` / `tado_dome_enrichment_queue_depth`** FFI
  shims so Swift can drive the same surfaces as agents. Used by the
  Knowledge → System backfill chip and the new lifecycle bindings
  in `DomeRpcClient` (`SupersedeResult` / `VerifyResult` /
  `DecayResult` / `EnrichmentQueueDepth` types).

- **RunEventWatcher v2 — structured retros.** Sprint completions,
  Eternal-run completions, and Dispatch-run completions now write a
  *structured* retro alongside the legacy one-line markdown. The
  body uses the recipe shape (`## Outcome / ## Decision / ## Caveats
  / ## Cite / ## Next agent should know`) so the deterministic
  extractor lifts each section into its own typed `graph_node` +
  edge. Deduper chains repeats via supersede when RunEventWatcher
  fires twice on the same `(runID, sprintN, kind)` tuple.

- **Knowledge → System "backfill chip"** — visible whenever the
  enrichment queue has any queued or running jobs. Hides at
  pipeline idle. Fed by the new
  `DomeRpcClient.enrichmentQueueDepth()` binding.

### Added — Context Packs v2 (Phase 4)

The spawn-time preamble engine moves from Swift to Rust, with
60-second caching, supersede/verify/decay invalidation, and a
deterministic byte-stable contract pinned by integration tests on
both sides. Dark-launched in v0.10 behind `dome.contextPacksV2`
(default `false`); v0.11 will flip the default and v0.12 will
retire the Swift composer. Every bootstrapped project keeps the
exact `<!-- tado:context:begin -->` / `<!-- tado:context:end -->`
marker contract.

- **`tado-core/crates/bt-core/src/context/`** — new module:
  `relative.rs` (deterministic relative-time formatter) +
  `spawn_pack.rs` (the pack engine itself). 14 unit tests +
  4 byte-equivalence integration tests pin the contract:
  `fixture_solo_agent_no_project`, `fixture_full_team_with_recent_notes`,
  `fixture_project_only_no_team_no_notes`,
  `fixture_marker_contract_is_locked`. Goldens encode the exact
  bytes — every bootstrapped agent's preamble lookup depends on this.

- **Deterministic relative-time formatter.** v0.10 used Apple's
  `RelativeDateTimeFormatter` which produces locale-specific
  strings (`"5 min. ago"` / `"hace 5 min."`). Phase 4 standardises
  on a fixed shape that's cheap to mirror in Rust:
  `just now / {n}m ago / {n}h ago / {n}d ago / {n}w ago / {n}mo ago
  / {n}y ago` (with `in {…}` for future timestamps). The Swift
  composer was updated to use this formatter so both sides render
  byte-identical output.

- **`spawn_pack_get_or_build` service method** — keyed by
  `(project_id, agent_name)`. Pulls reranked recent notes via the
  existing `note_chunks` + `graph_nodes` join (Phase 3 confidence /
  supersede / last_referenced_at all flow through), composes the
  preamble, caches in-memory for 60 seconds. Cache invalidation
  hooks fire from `note_supersede`, `note_verify`, and `node_decay`
  paths so the next spawn for the affected project always picks up
  the new state.

- **`tado_dome_compose_spawn_preamble` FFI** + new RPC method
  `context.spawn_pack`. Both wrap the same service method. Swift's
  `DomeContextPreamble.build(for:)` becomes a dual path: when the
  feature flag is on it delegates via FFI; otherwise it runs the
  v0.10 Swift composer verbatim. Both produce byte-identical output
  (verified by the integration test pair).

- **`GlobalSettings.dome.contextPacksV2`** — new default-`false`
  flag. Also accepts `TADO_DOME_CONTEXT_PACKS_V2=1` env override
  for spawn-time scenarios that don't have main-actor access. Read
  via `AtomicBool` so any thread can poll without main-actor hop.

### Added — Retrieval recipes + governed answers (Phase 5)

The capstone of the Knowledge Catalog upgrade. Three baseline
intents (`architecture-review`, `completion-claim`, `team-handoff`)
ship as deterministic recipes — each one bundles a retrieval
policy (topics, knowledge kinds, scope, freshness window,
minimum-confidence threshold) plus a markdown template that
renders into a synthesised answer with citations and an explicit
"missing authority" gap report. No LLM in the loop: the
synthesis is template substitution, the policy is what makes
the answer governed.

- **`tado-core/crates/bt-core/src/recipes/`** — three modules:
  `mod.rs` (types: `RetrievalRecipe`, `RetrievalPolicy`,
  `GovernedAnswer`, `Citation`; loader + upsert), `template.rs`
  (tiny placeholder substitution: `{{ var }}` and
  `{{ list | bullets(N) }}`), `runner.rs` (apply a recipe end-to-
  end). 13 unit tests.

- **Three baked recipes** — markdown templates committed at
  `tado-core/crates/bt-core/recipes/{architecture-review,
  completion-claim, team-handoff}.md` and `include_str!`'d into
  the binary. `service.recipe_seed_defaults` upserts them at
  global scope on every launch, idempotently. Users can override
  per project by dropping `<project>/.tado/verified-prompts/<intent>.md`
  files — the runner reads the on-disk path first, falls back to
  the baked default, and finally to a stub.

- **`dome_recipe_list` / `dome_recipe_apply` MCP tools.**
  `dome-mcp` inventory grew from 16 → 18. `dome_recipe_apply`
  takes `intent_key` (and optional `project_id`), runs the recipe's
  policy as a `HybridQuery` with rerank logging, separates hits
  into citations vs `missing_authority`, and returns the
  rendered template plus those structured fields.

- **Project-scope-wins resolution.** `load_recipes` returns
  project-scoped recipes that shadow globals on shared
  `intent_key`. Two-pass design so DB iteration order doesn't
  affect the outcome.

- **Migration 24 — activation marker.** Schema bumps to v24.
  Stamps a `schema_activation_log` row so dome-eval can audit
  when the v0.10 stack landed; downstream code can require v24
  for new behaviours. Pure stamp; no destructive DDL.

- **Bootstrap knowledge prompt refresh.** Adds the recipe contract
  + the three baseline intents to every project's CLAUDE.md /
  AGENTS.md "Knowledge & Memory" section. Existing projects re-run
  "Bootstrap knowledge layer" to pick up the v0.10 contract.

- **Recipe retrieval logged separately.** The recipe runner sets
  `RetrievalCtx.tool = "dome_recipe_apply:<intent_key>"` so
  `dome-eval replay` can score recipe hits as a distinct group
  from raw `dome_search` calls.

### Migration notes

- The first launch on v0.10.0 triggers the model download
  (~1.19 GB F16). Operators behind proxies can pre-download the
  four files into any directory and use the onboarding panel's
  "Choose…" button (writes `TADO_DOME_EMBEDDING_MODEL_PATH` for
  the rest of the session) instead.
- **Schema is now v24.** Migrations 23 (Phase 1 — entity columns
  + retrieval log) and 24 (Phase 5 — activation marker) are
  purely additive. Existing v0.9.0 vaults walk through both
  without backfill blocking app launch; the enrichment workers
  drain the queue at low priority once the daemon boots.
- Existing v0.9.0 vaults work without changes. Legacy `noop@1`
  384-dim chunks stay queryable through the FTS5 lexical lane;
  re-running "Bootstrap vectors" in Knowledge → Embeddings after
  the model loads upgrades them to qwen3 embeddings.
- Projects created before v0.10.0 are not auto-indexed —
  Settings → Code indexing → Re-index seeds the chunk table.
  After that, the watcher takes over on save.
- **Schema is now v23.** Migration 23 is purely additive: existing
  rows get safe defaults (`confidence=0.7`, `entity_version=1`,
  `source_signal='manual'`, `signal_confidence=0.7`), nullable
  lifecycle columns stay NULL until written. No backfill is
  required for v0.10; future releases (v0.12+) drain
  `pending_enrichment` in the background to populate the
  enriched fields without blocking app launch. The migration
  re-runs cleanly on existing v22 vaults — every ALTER is guarded
  by `table_has_column`, every CREATE uses `IF NOT EXISTS`.

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
