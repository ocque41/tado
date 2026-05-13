# AGENTS.md

This is the operating guide for AI agents working in `/Users/miguel/Documents/tado`.

Tado is a macOS app that runs multiple AI coding agents as terminal tiles on a shared canvas. The app is a SwiftUI shell with a Rust core for terminals, IPC, settings, Dome knowledge, MCP bridges, and long-running evaluation machinery.

This file is intentionally detailed. Read it before making architectural changes.

## Source Of Truth

1. The code wins.
2. `CLAUDE.md` is the canonical architecture contract. If it conflicts with code, fix the code or update `CLAUDE.md` in the same change.
3. This `AGENTS.md` is the agent entrypoint. Keep it aligned with `CLAUDE.md`.
4. `README.md`, `CHANGELOG.md`, `REWRITE.md`, and `docs/*` give useful context, but some details are historical. Do not treat them as stronger than code or `CLAUDE.md`.

If you change a contract, update every surface that teaches or depends on it:

- Swift UI and services
- Rust core and FFI
- C header
- tests
- bootstrapped prompts in `ProcessSpawner.swift`
- `CLAUDE.md`
- this file when agent behavior changes

## First Pass For Any Task

Start with the real repo, not assumptions.

```bash
pwd
git status --short
git branch --show-current
rg --files
```

Then read the smallest set of files that fully explains the requested area. For broad or architectural work, read:

- `CLAUDE.md`
- `Package.swift`
- `Makefile`
- `tado-core/Cargo.toml`
- relevant Swift files under `Sources/Tado`
- relevant Rust crates under `tado-core/crates`
- relevant tests under `Tests/TadoCoreTests` and Rust crate tests

Generated, vendored, and runtime directories are not source of truth:

- `.build/`
- `.build 2/`
- `tado-core/target/`
- `tado-core/target 2/`
- `tado-mcp/node_modules/`
- `.tado/eternal/runs/`
- `.tado/dispatch/runs/`
- `/tmp/tado-ipc*`
- session logs and app cache output

Do not spend time reverse-engineering build output unless debugging a build artifact or linker issue.

## Working Rules

- Understand architecture before editing.
- Keep changes scoped.
- Prefer existing patterns unless they are the cause of the bug.
- Challenge weak assumptions, but keep the explanation simple.
- Do not modify files, databases, infrastructure, or external systems when the user asks for analysis only.
- Do not use destructive commands unless the user explicitly approved them.
- Do not revert user work.
- Run the most relevant verification after implementation.
- For documentation-only edits, a build is usually unnecessary. Say that clearly.
- This repo does not use Supabase. Tado state is local JSON plus local SQLite in the Dome vault.

## Hard Project Invariants

These are not style preferences. Preserve them.

1. No dispatch watchdogs, auto-retries, or synthetic timeouts in the Dispatch/Eternal execution chain. Fail visibly, diagnose, and fix the root cause.
2. Storage-root writes must be atomic. Swift uses `AtomicStore`; Rust uses `tado-settings::write_json`. Never directly overwrite canonical settings JSON.
3. Migrations are additive only. Use `IF NOT EXISTS` or guarded `ALTER TABLE`; never assume a destructive schema rewrite is safe.
4. FFI and UI must ship together. A new user-relevant Rust RPC needs the Rust shim, C header, Swift `DomeRpcClient` or `TadoCore` binding, and UI/API surface in the same release.
5. Agent-facing tools must be taught to spawned agents. Update the bootstrap prompt functions in `Sources/Tado/Services/ProcessSpawner.swift` when tools, contracts, or workflows change.
6. Spawn-pack bytes are public API. Preserve `<!-- tado:context:begin -->`, `<!-- tado:context:end -->`, and fragment order across Swift and Rust.
7. Do not add ACL machinery. This is a single-user laptop app. Scope filters and the existing write barrier are the access model.
8. Destructive UI actions need a critical `NSAlert`, with Cancel as the default.
9. New non-UI logic should be Rust-first when it concerns persistence, IPC, atomic IO, settings, scheduling, retrieval, or cross-process contracts.
10. Treat a feature change as a full-system change. Check UI, state, settings, Swift/Rust bridge, CRUD, filters, tests, and docs.

## Build And Test Commands

Common commands:

```bash
swift build
swift run Tado
swift test
make dev
make build
make mcp
make core
make all-test
```

Rust:

```bash
cd tado-core && cargo test --workspace
cd tado-core && cargo build --release
cd tado-core && cargo test -p bt-core
cd tado-core && cargo test -p tado-settings
cd tado-core && cargo test -p tado-ipc
```

Perf and sprint gates:

```bash
make perf-suite
make perf-test
make perf-bench
cd tado-core && cargo test -p sprint-suite
```

FFI/header sync:

```bash
make sync-header
```

Use focused tests when the change is small. Use broad tests when touching shared contracts, storage, renderer, IPC, Dome, or process spawning.

## Repository Map

Top-level:

- `Package.swift` - Swift Package Manager manifest for the macOS app, C target, and bridge executable.
- `Makefile` - common build, header sync, MCP, plugin, perf, and Rust targets.
- `CLAUDE.md` - canonical architecture and invariants.
- `BRAND.md` - visual design contract.
- `CHANGELOG.md` - release notes and recent feature history.
- `docs/` - persistence, Dome reliability, and roadmap context.
- `.tado/` - project-local Tado config and project memory scaffolding.
- `.github/workflows/swift.yml` - CI currently runs `swift build -v` on macOS.

Swift app:

- `Sources/Tado/TadoApp.swift` - app bootstrap, SwiftData cache, migrations, extensions, lifecycle hooks.
- `Sources/Tado/Models/` - SwiftData models and app enums.
- `Sources/Tado/Views/` - SwiftUI surfaces.
- `Sources/Tado/Services/` - process spawning, IPC broker, settings sync, Eternal/Dispatch services, Tado Use, project indexing.
- `Sources/Tado/Persistence/` - atomic store, migrations, storage root, scoped config, backups.
- `Sources/Tado/Core/TadoCore.swift` - Swift wrapper around Rust terminal FFI.
- `Sources/Tado/Rendering/` - Metal terminal renderer, glyph atlas, shader pipeline.
- `Sources/Tado/Extensions/` - compile-time extension host and bundled extensions.
- `Sources/CTadoCore/include/tado_core.h` - C ABI consumed by Swift.
- `Sources/TadoUseBridge/` - bridge executable for Tado Use tools.

Rust workspace:

- `tado-core/Cargo.toml` - workspace manifest.
- `tado-core/crates/tado-terminal` - PTY, VT parser, terminal grid, FFI staticlib surface.
- `tado-core/crates/bt-core` - Dome knowledge service, SQLite schema, RPC mutator, retrieval, automations, graph, notes.
- `tado-core/crates/tado-ipc` - IPC paths, registry, external messages, event socket.
- `tado-core/crates/tado-settings` - atomic JSON IO, storage paths, scope enum.
- `tado-core/crates/tado-cli` - typed CLIs such as `tado-bootstrap`, `tado-dispatch`, `tado-eternal`, `tado-kanban`, `tado-system`, `tado-cowork`, `tado-deploy`, `tado-tui`.
- `tado-core/crates/tado-mcp` - Rust MCP bridge for Tado canvas/tools.
- `tado-core/crates/dome-mcp` - Rust MCP bridge for Dome tools.
- `tado-core/crates/tado-dome` - Dome CLI.
- `tado-core/crates/dome-eval` - retrieval evaluation.
- `tado-core/crates/perf-suite` - performance gate suite.
- `tado-core/crates/sprint-suite` - sprint success gate suite.
- `tado-core/crates/tado-eternal-state` - Eternal state model shared by gates.
- `tado-core/crates/tado-shared` - shared Rust primitives.

Legacy/reference:

- `tado-mcp/` is the older Node/TypeScript MCP implementation. Runtime should prefer the Rust MCP bridge under `tado-core/crates/tado-mcp` unless explicitly working on the legacy reference.

Tests:

- `Tests/TadoCoreTests/` covers terminal core, Metal rendering, model defaults, storage paths, Dome app state, search, event ledger, polish, lenses, and perf/sprint model compatibility.
- Rust crate tests live beside the Rust modules.

## Architecture Snapshot

Tado keeps two main SwiftUI surfaces alive:

- todo/list/detail surfaces
- canvas/terminal surfaces

The canvas must not destroy active terminal views just because navigation changes. Existing code uses mounted views with opacity/visibility changes to avoid killing PTYs.

The terminal stack is Rust-first:

- Swift decides what to spawn.
- `ProcessSpawner` composes shell commands, environment, bootstrap prompts, engine flags, and fallback behavior.
- `TerminalManager` owns session lifecycle and wires spawned sessions to todos, runs, and pollers.
- `TadoCore.Session` wraps Rust `TadoSession *`.
- Rust owns PTY reader threads, VT parsing, dirty snapshots, title/bell/mouse state, and process kill.
- Metal renders dirty snapshots in Swift.

Dome is in-process:

- `DomeExtension.onAppLaunch()` starts the Rust bt-core daemon through FFI.
- bt-core opens the vault, applies migrations, starts RPC, and owns SQLite.
- Swift talks to Dome through typed FFI/RPC helpers in `DomeRpcClient`.
- agents talk to Dome through `dome-mcp` or `tado-dome`.

IPC is local:

- `IPCBroker` creates `/tmp/tado-ipc-<pid>` and stable `/tmp/tado-ipc`.
- helper CLIs are installed into the IPC bin and `~/.local/bin`.
- `tado-list`, `tado-read`, `tado-send`, and `tado-deploy` are the main A2A tools.
- `tado-events` subscribes to the real-time event socket.

SwiftData is a cache:

- canonical app/settings/project data is JSON on disk.
- SwiftData cache can be rebuilt.
- corrupt SwiftData should be treated as disposable cache, not primary data.

## State And Storage

Default storage root:

```text
~/Library/Application Support/Tado/
```

Important storage areas:

- `global.json` - user-global settings.
- `projects/index.json` - project registry.
- `events/current.jsonl` - durable event log.
- `dome/` - Dome vault and SQLite store.
- `backups/` - migration and export backups.
- `cache/` - disposable cache.
- `logs/` - runtime logs.

Project-local state:

```text
<project>/.tado/
|-- config.json
|-- local.json
|-- memory/project.md
|-- memory/notes/
|-- eternal/runs/<uuid>/
|-- dispatch/runs/<uuid>/
`-- kanban/
```

Scope precedence:

1. runtime override
2. project local
3. project shared
4. user global
5. built-in defaults

Project commit policy controls what should be shared:

- `shared` - project config and memory can be committed.
- `local-only` - keep project Tado state out of git.
- `hybrid` - share safe config, keep private runtime state local.

Use the existing `ScopedConfig`, `StorePaths`, `StorageLocationManager`, and Rust `tado-settings` helpers. Do not invent a second settings path.

## Persistence Rules

Canonical JSON writes must follow:

1. take lock
2. read and merge if needed
3. write temp file
4. fsync temp file
5. atomic rename
6. release lock

Swift:

- use `AtomicStore`
- use `AppSettingsSync` or `ProjectSettingsSync` for cache bridge behavior
- use `MigrationRunner` for storage-root migrations

Rust:

- use `tado_settings::write_json`
- use typed structs when the shape is known
- keep `writer` and `schemaVersion` fields meaningful

Never add direct `Data.write`, direct `FileManager` replacement, or ad-hoc JSON mutation for canonical stores.

## Migration Rules

Swift storage-root migrations:

- live under `Sources/Tado/Persistence/Migrations/`
- run through `MigrationRunner`
- create a pre-migration backup
- bump the migration marker only after success
- must be idempotent

Dome/bt-core SQLite migrations:

- live in `tado-core/crates/bt-core/src/migrations.rs`
- current `LATEST_SCHEMA_VERSION` is `24`
- add a new `migration_N` function
- append it to the migration runner
- use additive DDL
- add tests proving fresh migration and repeated migration are safe
- update schema/version text in `CLAUDE.md` when it changes

Do not delete columns or rewrite existing tables without an explicit, reviewed data migration plan.

## FFI Rules

Rust exports C ABI through `tado-terminal` and the public header.

When adding or changing FFI:

1. implement the Rust function and memory ownership.
2. expose it in the correct Rust FFI module.
3. update `tado-core/include/tado_core.h`.
4. run `make sync-header` so `Sources/CTadoCore/include/tado_core.h` matches.
5. update Swift wrapper code, usually `TadoCore.swift` or `DomeRpcClient.swift`.
6. add tests where practical.
7. verify with `swift build` and relevant Rust tests.

String ownership matters:

- Rust-allocated strings returned to Swift must be released with `tado_string_free`.
- Swift C strings passed into Rust must outlive the call.
- Keep JSON payloads typed at the Swift edge when the UI depends on them.

## Swift Patterns

Most app state is main-actor UI state.

Use existing singletons and environment objects:

- `AppState`
- `TerminalManager`
- `EventBus`
- `TadoUseState`
- settings and project sync services

Rules:

- do UI state mutation on `MainActor`
- keep blocking IO and process work off the main actor
- avoid per-token or per-frame SwiftUI invalidation of large arrays
- preserve active terminal mounts
- keep model defaults backward-compatible
- do not remove vestigial SwiftData fields without a migration reason

Important files:

- `TadoApp.swift` wires app launch, model container, migrations, extension hooks, event bridges, shutdown.
- `AppState.swift` defines app navigation, engine choices, model choices, and high-level UI state.
- `TerminalManager.swift` owns terminal sessions, kill/shutdown, fallback, and run wiring.
- `ProcessSpawner.swift` owns CLI command construction, env, bootstrap prompts, engine flags, and shell escaping.
- `IPCBroker.swift` owns local A2A files, helper script installation, event socket wiring, and spawn requests.

## Rust Patterns

Rust owns durable non-UI logic.

Prefer Rust for:

- IPC contracts
- atomic file writes
- settings paths and scope logic
- local SQLite migrations
- retrieval/search/ranking
- terminal parsing and PTY behavior
- gate suites
- MCP bridges

bt-core is the trusted Dome mutator. Avoid bypassing it with ad-hoc SQLite writes. If a UI feature needs to change Dome state, add a typed service/RPC/FFI path and tests.

The large files are large because they centralize contracts. Be careful in:

- `tado-core/crates/bt-core/src/service.rs`
- `tado-core/crates/bt-core/src/db.rs`
- `tado-core/crates/bt-core/src/migrations.rs`
- `tado-core/crates/tado-terminal/src/dome_ffi.rs`
- `Sources/Tado/Services/DomeRpcClient.swift`

## Terminal Renderer Rules

The terminal renderer is a Rust PTY plus Swift Metal renderer.

Do not change the cell ABI casually. If you change terminal cell layout:

- update Rust cell structs
- update Swift `TadoCore.Cell`
- update C header if exposed
- update tests that assert layout or rendering
- verify offscreen Metal tests

Rendering gotchas:

- `snapshotDirty()` is incremental and clears dirty flags.
- first render and resize need full snapshots.
- glyph atlas overflow recovery resets and refills.
- font fallback and emoji rendering are covered by tests.
- tile dimensions are stable layout constraints, not decorative values.

Relevant tests:

- `MetalRendererTests`
- `RendererBenchTests`
- `TadoCoreTests`
- `SelectionTests`
- `TileVisibilityTests`

## Design Rules

Use `BRAND.md` and Relay tokens.

Core rules:

- Plus Jakarta Sans for UI chrome.
- SF Mono for terminal grid only.
- use `Sources/Tado/Design/RelayTokens.swift` for new UI colors and spacing.
- foundation ink is `#1a1a1a`.
- foundation paper is `#f5f5f5`.
- terracotta accent is `#A44718` and should be restrained.
- default radius is `5.5 pt`.
- modals may use shadows; routine surfaces should not become floating card piles.
- legacy `Palette` tokens are compatibility aliases; new code should use Relay primitives.

Do not introduce a disconnected visual system.

## Dome And Knowledge

Dome is Tado's second brain. It includes notes, graph, retrieval, automations, context packs, code search, and agent status.

Key files:

- `Sources/Tado/Extensions/Dome/DomeExtension.swift`
- `Sources/Tado/Services/DomeRpcClient.swift`
- `Sources/Tado/Views/Dome*`
- `tado-core/crates/bt-core/src/service.rs`
- `tado-core/crates/bt-core/src/migrations.rs`
- `tado-core/crates/dome-mcp/src/main.rs`
- `tado-core/crates/tado-dome`

Dome reliability rules:

- prefer explicit lifecycle APIs over implicit refresh side effects.
- prefer typed FFI over ad-hoc JSON-RPC in desktop UI.
- note write/delete must produce a clear success/failure surface.
- alias behavior must be intentional and tested.
- destructive success-dominant behavior needs extra care because filesystem and SQLite delete are not fully atomic today.

For note features, verify:

- user note create/read/update/delete
- agent note create/read/update/delete
- project/global scope behavior
- offline daemon behavior
- UI state after mutation
- no generic "Dome may be offline" when the daemon is healthy and the payload is wrong

## Spawn Packs And Context

Spawn pack v2 is a byte-stable public contract.

Preserve:

- `<!-- tado:context:begin -->`
- `<!-- tado:context:end -->`
- fragment order
- Swift/Rust byte parity
- context citation shape

When changing context generation, update both sides and run the Rust byte-equivalence tests, especially `bt-core/tests/spawn_pack_byte_equiv.rs`.

`DomeContextPreamble` is pre-warmed on launch to reduce first tile spawn latency. Do not move blocking preamble generation onto the main actor.

## Process Spawning

`ProcessSpawner.swift` is central. Treat it as a contract surface.

It handles:

- Claude command construction
- Codex command construction
- Cowork URL-scheme launch
- model and effort flags
- permission modes
- bootstrap prompts
- PATH and `TADO_*` environment
- shell escaping
- engine fallback rules

Important constraints:

- shell-escape model flags because some model names contain brackets.
- `sanitizeFlags` protects auto-mode sentinels.
- fallback is bounded and user-visible; it is not a watchdog.
- new A2A tools or agent instructions must be added to bootstrap prompt functions:
  - `bootstrapPrompt`
  - `bootstrapTeamPrompt`
  - `bootstrapAutoModePrompt`
  - `bootstrapKnowledgePrompt`

## Cowork Engine

Cowork is a third engine, but it is not a normal PTY engine.

Facts:

- launched through `tado-cowork`
- opens Claude Desktop with `claude://cowork/new?...`
- no standalone Cowork CLI
- no PTY output
- output is watched from `<projectRoot>/.tado/cowork/<runID>.md`
- `CoworkOutputPoller` maps file updates back into Tado
- Cowork is not supported for Eternal or Dispatch execution
- Tado Use cannot drive Cowork per turn

Do not assume Cowork can be treated like Claude or Codex.

## Eternal, Dispatch, Perf, And Sprint

Eternal and Dispatch are long-running project workflows.

Key files:

- `Sources/Tado/Services/EternalService.swift`
- `Sources/Tado/Services/EternalServiceCoordinator.swift`
- `Sources/Tado/Services/DispatchPlanService.swift`
- `Sources/Tado/Services/DispatchPlanServiceCoordinator.swift`
- `Sources/Tado/Models/EternalRun.swift`
- `Sources/Tado/Models/DispatchRun.swift`
- `tado-core/crates/perf-suite`
- `tado-core/crates/sprint-suite`
- `tado-core/crates/tado-eternal-state`

Rules:

- no watchdogs, retries, or hidden restarts.
- phase outputs are contracts; parse them strictly.
- perf gate success emits `[PERF-OK]`.
- sprint gate success emits `[SCORE-OK]`.
- gate writes must use atomic store.
- successful retros and structured outputs should mirror to Dome when the existing flow expects that.
- do not break Cross-Run Browser state fields.

Perf and sprint are not decorative modes. They have state fields, tests, gates, and changelog history.

## Tado Use

Tado Use is the left-edge autonomous control panel.

Key files:

- `Sources/Tado/Views/TadoUsePanel.swift`
- `Sources/Tado/Services/TadoUseEngine.swift`
- `Sources/Tado/Services/TadoUseAutonomousHandlers.swift`
- `Sources/Tado/Services/TadoUseBridgeHandlers.swift`
- `Sources/Tado/Services/TadoUseBridgeAutoRegister.swift`
- `Sources/Tado/Services/TadoUseState.swift`
- `Sources/TadoUseBridge/main.swift`

Constraints:

- one subprocess at a time per turn.
- Claude path uses `claude -p` with stream JSON and per-turn MCP config.
- Codex is surfaced as unsupported for Tado Use until CLI MCP config support exists.
- Cowork is surfaced as unsupported for Tado Use because it does not expose a per-turn MCP config path.
- `tado_use.todo_create` accepts optional `engine: "claude" | "codex"` for explicit tile spawning.
- Dispatch follow-ups use `tado_use.dispatch_intervene`; the run must have a live current-phase or architect tile.
- JSONL parsing and coalescing stay off the main actor.
- per-token streaming should not mutate large SwiftUI arrays.

## Kanban

Kanban state is per-project.

Important paths:

- `<project>/.tado/kanban/state.json`
- `<project>/.tado/kanban/inbox/`

Important CLI:

```bash
tado-kanban list
tado-kanban move <card-id> <column>
tado-kanban add-column <key> <title>
```

Use existing project root resolution. Do not create a second board format.

## Extensions

Extensions are compile-time bundled features, not dynamic plugins.

To add an extension:

1. add `Sources/Tado/Extensions/<id>/<Name>Extension.swift`.
2. conform to `AppExtension`.
3. add the type to `ExtensionRegistry.all`.
4. add a matching `WindowGroup(id: ExtensionWindowID.string(for:))` in `TadoApp.body`.
5. wire app launch behavior through `onAppLaunch()` only when needed.
6. add tests or smoke verification for open/window/lifecycle behavior.

Bundled extensions currently include:

- Notifications
- Dome
- Cross-Run Browser

## MCP And CLI Surfaces

Runtime MCP bridges:

- `tado-core/crates/tado-mcp`
- `tado-core/crates/dome-mcp`

Primary shell tools:

```bash
tado-list
tado-read
tado-send
tado-deploy
tado-events
tado-config
tado-notify
tado-memory
tado-dome
tado-bootstrap
tado-dispatch
tado-eternal
tado-kanban
tado-projects
tado-system
tado-cowork
```

If you change target resolution, message format, output format, or available tools:

- update Rust CLI/MCP code
- update Swift `IPCBroker` helper installation if relevant
- update bootstrap prompts
- update docs
- add parity tests where possible

## Tado A2A IPC

You have CLI tools for inter-terminal communication. Use these when asked to message, respond to, or interact with other Tado terminals.

```bash
tado-list
tado-read <target> [--tail N] [--follow] [--raw]
tado-send <target> <message>
tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]
```

Target resolution for `tado-read` and `tado-send`, in order:

1. exact UUID
2. grid coordinates: `1,1`, `1:1`, or `[1,1]`
3. name substring match

Typical workflow:

```bash
tado-list
tado-read 1,1 --tail 80
tado-send 1,1 "message"
```

### Contacting Another Agent

When sending first contact to another agent, include:

1. who you are
2. what you need
3. how to reply to you

Good:

```bash
tado-send 2,1 "I am the agent at [1,1] working on IPC in the tado project. I need the schema you generated. Reply with: tado-send 1,1 \"<schema>\""
```

Bad:

```bash
tado-send 2,1 "Can you send the schema?"
```

The recipient has no context unless you include it.

### Responding To Agent Requests

If another Tado terminal asks you for output, you must deliver it with `tado-send`.

Do not only answer in your own terminal. The other agent is waiting for a message.

Example:

```bash
tado-send 2,1 "Here is the answer: ..."
```

If the request is ambiguous, read their terminal first:

```bash
tado-read 2,1 --tail 120
```

Then send the actual answer.

### Deploying Agents

`tado-deploy` creates a new visible terminal tile on the Tado canvas. It is not the built-in Codex subagent tool.

Use it when a separate visible agent session is appropriate:

- specialized teammate
- independent implementation slice
- another engine on the canvas
- human-visible delegation

After deploying, stop immediately. Do not wait, list, or read the new terminal. The deployed agent should be instructed to send results back with `tado-send`.

Example:

```bash
tado-deploy "Generate TypeScript types for the auth API. When done, deliver results via: tado-send 1,1 '<types>'" --agent backend
```

Then stop and wait for the response.

### Message Origin Rules

Treat a message as agent-originated when it clearly self-identifies as a terminal or session, for example:

- "I am the agent at 3,1"
- "agent 2,1 here"
- a first-person question about another terminal's output

For agent-originated messages:

- answer with `tado-send <target> "<response>"`
- use `tado-list` if you need to resolve the sender
- deliver the requested content, not just a status update

Treat messages that do not identify as another terminal as user-originated.

## Bootstrap And Project Docs

Tado can inject A2A, team, auto-mode, and knowledge instructions into other projects.

The source text for these injections is in `ProcessSpawner.swift`, not only in markdown docs. If you change how agents should use Tado tools, update the bootstrap prompt functions there.

Do not let this file, `CLAUDE.md`, and bootstrap output drift apart.

## Git And Worktree Safety

- Check `git status --short` before edits.
- Do not overwrite unrelated dirty files.
- Do not run `git reset --hard`.
- Do not run `git checkout -- <file>` to discard user work unless explicitly asked.
- Do not stage or commit unless the user asks.
- If generated files change because of a build, inspect whether they are tracked before deciding what to do.

## Verification Matrix

Choose the smallest verification that proves the change.

Documentation only:

- inspect rendered markdown/diff
- no build required unless docs affect generated behavior

Swift UI/service change:

```bash
swift build
swift test
```

Rust crate change:

```bash
cd tado-core && cargo test -p <crate>
```

FFI change:

```bash
make sync-header
swift build
cd tado-core && cargo test -p tado-terminal
```

Dome schema/service change:

```bash
cd tado-core && cargo test -p bt-core
swift test --filter Dome
```

Renderer change:

```bash
swift test --filter MetalRendererTests
swift test --filter RendererBenchTests
swift test --filter TadoCoreTests
```

IPC/MCP change:

```bash
make mcp
cd tado-core && cargo test -p tado-ipc -p tado-mcp -p dome-mcp
```

Eternal/perf/sprint change:

```bash
swift test --filter EternalPerfModelTests
make perf-suite
cd tado-core && cargo test -p sprint-suite
```

Always report:

- what was verified
- what failed
- what was not verified
- why skipped checks were skipped

## Common Failure Modes

Spawn failures:

- stale CLI flags
- model names not shell-escaped
- missing Claude/Codex binary on login shell PATH
- invalid auto-mode sentinels
- Cowork treated like PTY engine

Terminal rendering failures:

- dirty snapshot consumed too early
- full snapshot missing after resize
- glyph atlas overflow not recovered
- cell ABI mismatch between Rust and Swift

Storage failures:

- direct JSON writes causing torn files
- SwiftData treated as canonical
- settings path duplicated outside `StorePaths`/`SettingsPaths`
- migration not idempotent

Dome failures:

- daemon offline hidden behind a generic UI message
- payload does not match actor schema
- ad-hoc JSON-RPC instead of typed FFI
- SQLite schema changed without additive migration
- note delete partially succeeds across DB/filesystem boundary

IPC failures:

- `/tmp/tado-ipc` symlink points to old process
- helper scripts not reinstalled after contract change
- target resolution changes not mirrored across CLI and MCP
- agent first-contact messages missing return instructions

UI failures:

- terminal tiles unmounted during navigation
- heavy parsing on `MainActor`
- visible text or controls overflow their container
- new UI bypasses Relay tokens

## When To Update This File

Update `AGENTS.md` when:

- agent workflow changes
- Tado CLI or MCP tools change
- project invariants change
- build/test commands change
- storage, migration, FFI, or bootstrap contracts change
- a repeated failure mode becomes known

Keep it blunt and operational. Future agents should be able to act from it without rediscovering the whole project.
