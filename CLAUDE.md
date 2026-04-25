# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build          # Build the project
swift run            # Build and run the app
make dev             # Build Rust core (release) + run Swift app
cargo test -p tado-ipc -p tado-settings   # Run Rust-side unit tests
```

The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+) plus a Cargo workspace under `tado-core/` (see Architecture for the split).

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

**State flow:** `TadoApp` creates two `@Observable` singletons — `AppState` (UI state) and `TerminalManager` (session lifecycle) — injected via SwiftUI `.environment()`. `SwiftData` persists `TodoItem` and `AppSettings` models.

**Two views, always alive:** `ContentView` keeps both `TodoListView` and `CanvasView` mounted simultaneously, toggling via opacity. This prevents terminal processes from being destroyed when switching views. `Ctrl+Tab` switches between them.

**Todo submission flow:** User types text in `TodoListView` → `TodoItem` created (SwiftData) → `TerminalManager.spawnSession()` creates a `TerminalSession` → `TerminalNSViewRepresentable` bridges SwiftTerm's `LocalProcessTerminalView` into SwiftUI → `ProcessSpawner` builds the shell command (`/bin/zsh -l -c "claude 'todo text'"`) → process starts.

**Terminal activity detection:** A 1.5s repeating `Timer` in the `NSViewRepresentable` Coordinator monitors cursor position. If the cursor hasn't moved for 5 seconds, the session transitions to `.needsInput`, which triggers queue draining (queued follow-up prompts are sent automatically).

**Forward mode:** Clicking the arrow button on a todo row sets `appState.forwardTargetTodoID`. The next text submission goes to that terminal's session via `enqueueOrSend()` instead of creating a new todo. One-shot: forwarding deactivates after one message.

**Canvas layout:** `CanvasLayout` computes grid positions (660x440 tiles). Tiles are positioned absolutely in a `ZStack` with `scaleEffect` + `offset` for zoom/pan. `Shift+scroll` zooms; plain scroll pans (unless a terminal is focused, then it's terminal scrollback).

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

## Persistence (settings / memory / events)

All canonical state lives under `~/Library/Application Support/Tado/`:

```
settings/global.json        user-global settings (scope 4)
memory/user.md              user-level long-lived context
memory/user.json            user-level cached facts
events/current.ndjson       append-only event log (one JSON per line)
events/archive/*.ndjson     rotated daily
backups/tado-backup-*.tar.gz  auto-snapshot pre-migration + manual exports
cache/                      SwiftData store (rebuildable, not canonical)
version                     last-applied migration id
```

Per-project state lives under `<project>/.tado/`:

```
config.json                 project-shared settings (commit by default)
local.json                  project-local overrides (gitignored by default)
memory/project.md           long-lived project context
memory/notes/<ISO>-*.md     timestamped running notes
.gitignore                  auto-maintained by Tado (honors commitPolicy)
eternal/runs/<uuid>/        per-run state (existing)
dispatch/runs/<uuid>/       per-run state (existing)
```

**Scope hierarchy** (highest wins on merge): runtime > project-local > project-shared > user-global > built-in default.

**Canonical store is JSON files on disk**, atomically written via `AtomicStore` (flock + tmp + rename). SwiftData is a rebuildable cache fed by `AppSettingsSync` and `ProjectSettingsSync`. If the SwiftData store corrupts, `rm -rf cache/` and relaunch — it rebuilds from JSON.

**Event system** — every meaningful state transition (`terminal.completed`, `eternal.phaseCompleted`, `ipc.messageReceived`, user broadcasts) publishes a typed `TadoEvent` through `EventBus`. Deliverers subscribe: `SoundPlayer` (audio), `DockBadgeUpdater` (unread count), `SystemNotifier` (macOS banner), `InAppBannerOverlay` (transient pill), `EventPersister` (NDJSON log). Routing + mute + quiet hours are configured in `global.json → notifications`.

**CLI** (alongside `tado-list` / `-send` / `-read` / `-deploy`):
```bash
tado-config {get,set,list,path,export,import} [scope] [key] [value]
tado-notify {send "<title>",tail}
tado-memory {read,note,search,path} [scope]
```

**MCP** (via tado-mcp server, registered into Claude Code at user scope): `tado_config_{get,set,list}`, `tado_memory_{read,append,search}`, `tado_notify`, `tado_events_query`.

## Key Files

- `ProcessSpawner.swift` — Builds the CLI command for the selected engine
- `TerminalNSViewRepresentable.swift` — NSViewRepresentable bridge + activity monitoring Coordinator
- `TerminalSession.swift` — Session model with status FSM and prompt queue
- `CanvasLayout.swift` — Grid position math and tile dimensions
- `IPCBroker.swift` — File-based IPC broker, a2a inbox watcher, CLI tool generation
- `IPCMessage.swift` — IPC message model and registry types
- `Persistence/AtomicStore.swift` — atomic write + flock helper (shared Swift / CLI / bash)
- `Persistence/ScopedConfig.swift` — 5-scope config facade
- `Persistence/FileWatcher.swift` — debounced DispatchSource wrapper
- `Persistence/AppSettingsSync.swift` / `ProjectSettingsSync.swift` — JSON ↔ SwiftData bridges
- `Persistence/MigrationRunner.swift` + `Migrations/` — monotonic migration runner (auto-backup pre-apply)
- `Persistence/BackupManager.swift` — tarball snapshot + restore
- `Events/EventBus.swift` + `Events/TadoEvent.swift` — pub/sub hub
- `Events/EventPersister.swift` — NDJSON appender + daily rotation
- `Events/Deliverers/*.swift` — SoundPlayer, DockBadgeUpdater, SystemNotifier
- `Events/RunEventWatcher.swift` — diff state.json / phases/ to emit eternal/dispatch events
- `Views/InAppBannerOverlay.swift` — transient banner stack
- `Views/NotificationsView.swift` — full history view (sidebar bell opens this)

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
   `cd tado-mcp && npm run build` (MCP server). Do not release if
   either fails — fix first.
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
