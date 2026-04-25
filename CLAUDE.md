# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                                  # Build the Swift app
swift run                                    # Build and run
make dev                                     # Build Rust core (release) + sync header + run Swift app
make mcp                                     # Build dome-mcp + tado-mcp stdio bridges (Rust [[bin]]s)
cargo test -p tado-ipc -p tado-settings      # Rust unit tests for IPC + settings crates
```

The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+)
plus a Cargo workspace under `tado-core/` with eight crates:
`tado-terminal` (PTY + grid + VT parser + cbindgen FFI),
`tado-shared` (cross-crate primitives),
`tado-ipc` (IPC contract types + registry serialization),
`tado-settings` (atomic JSON IO + 5-scope enum + path helpers),
`bt-core` (the trusted-mutator notes/automation/JSON-RPC crate fused from Dome),
`dome-mcp` and `tado-mcp` (the two stdio MCP bridges, both Rust `[[bin]]`s),
and `tado-dome` (CLI for canvas agents to register/query scoped Dome knowledge).
Every member links into the same `libtado_core.a` Package.swift consumes.

## Conventions (foundation-v2 and beyond)

- **Rust-first for new non-UI logic.** When you're adding persistence, IPC, atomic file IO, settings merging, scheduling, or anything that's fundamentally systems-y — write it in Rust inside the `tado-core/` workspace (one of `tado-terminal`, `tado-shared`, `tado-ipc`, `tado-settings`, future crates as they arrive). Swift is for views + thin bindings + macOS-specific integrations (NSView bridges, NSPasteboard, SwiftUI plumbing, AppKit glue).
- **The write barrier stays.** Every mutation that reaches disk goes through the atomic-store discipline (temp + sync + rename). Do not bypass it.
- **No new safety systems around dispatch.** Per the existing feedback rule: no watchdogs, auto-retry, or timeouts for the agent-dispatch chain. Existing retry policies on long-running automations stay as-is; don't add new ones.
- **Extensions-first for optional features.** If a feature is valuable but optional (examples: Eternal, Dispatch, Notifications), ship it as an extension using the `AppExtension` protocol in `Sources/Tado/Extensions/`. Core Tado stays "canvas of agent terminals" plus the minimum UI shell.
- **Compile-time extension registry.** Adding an extension = (1) new Swift type conforming to `AppExtension`, (2) entry in `ExtensionRegistry.all`, (3) matching `WindowGroup(id: ExtensionWindowID.string(for:))` block in `TadoApp.body`. No dynamic loading for v0.
- **Treat every feature change as a full-system change until proven otherwise.** Do not stop at the literal UI tweak the user asked for. When a feature already exists, trace and update every affected layer: window wiring, state, settings precedence, Swift views, Rust services, FFI, create/read/update/delete paths, filtering, and tests. If you add a field, scope, toggle, topic, or action, check the whole lifecycle so the feature still works end to end after the change.
- **Prefer typed Swift↔Rust bindings over ad-hoc JSON-RPC payloads.** For desktop UI bindings, call typed Rust service methods through dedicated FFI when possible. Avoid hand-building actor/method JSON at the Swift bridge unless the feature truly needs generic RPC. If JSON-RPC is unavoidable, support legacy field aliases deliberately and test the full request shape end to end.

## What This Is

Tado is a macOS SwiftUI app that turns a todo list into a terminal multiplexer for AI coding agents. Each todo item spawns a terminal running either `claude` (Claude Code) or `codex` CLI with the todo text as the prompt. Terminals are displayed as tiles on a pannable/zoomable canvas.

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
`TerminalSession` → `MetalTerminalTileView` mounts the Metal tile →
`ProcessSpawner` builds the shell command (`/bin/zsh -l -c "claude
'todo text'"` with shell-escaped flags including `--model`/`--effort`)
→ Rust `tado-terminal` spawns the PTY via `portable-pty`, parses VT
sequences in `performer.rs`, and snapshots the cell grid for the
renderer to draw.

**Metal renderer:** The terminal view is a Metal pipeline
(`MetalTerminalRenderer` + `GlyphAtlas` + `Shaders.metal`). SwiftTerm
was removed in v0.7.0; every tile uses the Rust+Metal stack. Wide-char
support, color-emoji RGBA atlas, retina-aware text, ANSI palette
theming (15 curated themes), live tile resize, scrollback clamp.

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
tiles). Tiles are positioned absolutely in a `ZStack` with
`scaleEffect` + `offset` for zoom/pan. `Shift+scroll` zooms; plain
scroll pans (unless a terminal is focused, then it's terminal
scrollback).

## Tado A2A (Agent-to-Agent IPC)

Tado exposes CLI tools at `~/.local/bin/` for inter-terminal communication. **Use these when asked to message, respond to, or interact with other Tado terminals.**

```bash
tado-list                          # List all active sessions (ID, engine, grid, status, name)
tado-read <target> [--tail N] [--follow] [--raw]  # Read terminal output from a session
tado-send <target> <message>       # Send typed input to a terminal session
tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]  # Deploy a new agent session on the Tado canvas
```

**Target resolution** (same for `tado-read` and `tado-send`, in priority order):
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
tado-deploy "implement auth module" --agent backend  # Deploy a backend agent on the canvas
```

**Typical workflow for responding to a terminal:** `tado-read 1,1` to see what it output, then `tado-send 1,1 "your response"` to reply.

**Deploying agents:** `tado-deploy` is a Tado IPC command that creates a new terminal tile on the Tado canvas — it is NOT your built-in subagent or background agent tool. Use it to deploy a new agent session that gets its own tile, grid position, and IPC registration. Defaults (project, team, engine, cwd) are inherited from the calling session's environment. The agent name corresponds to definitions at `.claude/agents/<name>.md`.

**Fire-and-forget pattern:** When deploying, include in the deployed agent's prompt instructions to deliver results back via `tado-send <your-grid>`. Then STOP — do not wait, do not run tado-list, do not read the deployed agent's terminal log. The deployed agent will `tado-send` results back to you, which will wake you. Example: `tado-deploy "analyze the codebase and deliver results via tado-send 1,1" --agent analyst`

**Contacting other agents:** When you send a message via `tado-send`, always identify yourself and tell the recipient how to respond. Include your grid position (e.g., `[1,1]`), your project, and instruct them to reply with `tado-send <your-grid> "<response>"`. The receiving agent has no context about who sent the message unless you include it. Once a conversation is established, you can skip the full introduction.

**Responding to agent requests:** When another agent sends you a message asking for something, you **must** deliver the requested information back via `tado-send <their-grid> "<response>"`. This is not optional — the requesting agent is waiting. Do not just print the answer in your own terminal; send it back to them.

**Working in a team:** When you are part of a team, you share a project with other specialized agents. Know your teammates — read their agent definitions at `.claude/agents/<name>.md` to understand their roles. Use `tado-list` to find running teammates. When a teammate asks you for something, deliver it back to them via `tado-send`. When you need something from a teammate, send a request and they will deliver back to you.

**IPC internals:** File-based via `/tmp/tado-ipc/`. Each session has `inbox/`, `outbox/`, and `log` in its directory. Terminal output is flushed to the `log` file every 5 seconds. External messages go to `/tmp/tado-ipc/a2a-inbox/`. See `IPCBroker.swift` and `IPCMessage.swift`.

## Persistence (settings / memory / events / Dome)

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
rebuildable cache fed by `AppSettingsSync` and `ProjectSettingsSync`.
If the SwiftData store corrupts, `rm -rf cache/` and relaunch — it
rebuilds from JSON.

**Dome second brain** — `bt-core` runs in-process inside the Tado
`.app` (booted by `DomeExtension.onAppLaunch` via the FFI entry
`tado_dome_start`). Vault is at `<storage-root>/dome/`, the Unix
socket at `<vault>/.bt/bt-core.sock`. Schema is at version 21; new
chunks use Qwen3-Embedding-0.6B (1024-dim) while legacy 384-dim
`noop@1` rows continue to work. Every project auto-seeds a
`project-<shortid>` topic; teams add `team-<sanitized-name>` notes;
Eternal sprint+completion retros mirror as structured notes.
Spawn-time agents wake with a markdown context preamble (identity +
project + team + recent notes) wrapped in `<!-- tado:context:begin -->`
markers.

**Event system** — every meaningful state transition
(`terminal.completed`, `eternal.phaseCompleted`, `ipc.messageReceived`,
`dome.daemonStarted`, user broadcasts) publishes a typed `TadoEvent`
through `EventBus`. Deliverers subscribe: `SoundPlayer` (audio),
`DockBadgeUpdater` (unread count), `SystemNotifier` (macOS banner),
`InAppBannerOverlay` (transient pill), `EventPersister` (NDJSON log),
`EventsSocketBridge` (real-time fanout to subscribers on
`/tmp/tado-ipc/events.sock`). Routing + mute + quiet hours are
configured in `global.json → notifications`.

**CLI** (alongside `tado-list` / `-send` / `-read` / `-deploy`):
```bash
tado-config {get,set,list,path,export,import} [scope] [key] [value]
tado-notify {send "<title>",tail}
tado-memory {read,note,search,path} [scope]
tado-events [filter]                 # subscribe to events.sock; filter = "*", "topic:foo", "session:<id>", or kind prefix
tado-dome {register,query,…} …       # scoped Dome knowledge from canvas agents
tado-list --toon                     # AXI-style compact output (~45% fewer tokens for agents)
```

**MCP** — both bridges are Rust `[[bin]]`s now, auto-registered into
Claude Code at user scope on first launch (silent fallback if
`claude` CLI is missing). `tado-mcp` exposes:
`tado_config_{get,set,list}`, `tado_memory_{read,append,search}`,
`tado_notify`, `tado_events_query`, `tado_list`, `tado_send`,
`tado_read`, `tado_broadcast`. `dome-mcp` exposes:
`dome_search`, `dome_read`, `dome_note`, `dome_schedule`,
`dome_graph_query`, `dome_context_resolve`, `dome_context_compact`,
`dome_agent_status` — agents must use the latter four before making
stale architecture or completion claims.

## Key Files

**Spawning + sessions**
- `Services/ProcessSpawner.swift` — builds the CLI command for the selected engine; shell-escapes flags
- `Services/TerminalManager.swift` — session lifecycle, registry sync, idle detection
- `Models/TerminalSession.swift` — session model + status FSM (`pending` / `running` / `needsInput` / `awaitingResponse` / `completed` / `failed`) + prompt queue

**Renderer**
- `Rendering/MetalTerminalView.swift` / `MetalTerminalTileView.swift` / `MetalTerminalRenderer.swift` — Metal pipeline
- `Rendering/GlyphAtlas.swift` + `Shaders.metal` — glyph cache + shaders
- `Rendering/FontMetrics.swift` — monospace font metrics via `NSFont.monospacedSystemFont`
- `tado-core/crates/tado-terminal/src/{ffi,grid,performer,pty,session}.rs` — Rust PTY + VT parser + cell grid

**Canvas + UI**
- `Views/CanvasView.swift` + `CanvasLayout` — grid position math, zoom/pan, tile placement
- `Views/SidebarView.swift` — projects, teams, sessions, notifications bell
- `Views/SettingsView.swift` — picker grids, storage relocator, notifications routing

**IPC + extensions**
- `Services/IPCBroker.swift` — file-based broker, a2a inbox watcher, CLI tool generation
- `Services/EventsSocketBridge.swift` — fans `EventBus` to `/tmp/tado-ipc/events.sock`
- `Services/TadoMcpAutoRegister.swift` — auto-`claude mcp add tado` on launch
- `Models/IPCMessage.swift` — IPC envelope + registry types
- `tado-core/crates/tado-ipc/src/` — Rust mirror of IPC contract + registry serialization
- `Extensions/AppExtensionProtocol.swift` + `ExtensionRegistry.swift` + `ExtensionsPageView.swift` — extension host
- `Extensions/Notifications/NotificationsExtension.swift` + `NotificationsWindowView.swift` — notifications surface
- `Extensions/Dome/DomeExtension.swift` + `DomeRpcClient.swift` + `Surfaces/*` — Dome surfaces (User Notes, Agent Notes, Calendar, Knowledge)
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
- `tado-core/crates/tado-terminal/src/{dome_ffi,sibling_ffi}.rs` — FFI bridge to Swift
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
