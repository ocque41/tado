# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build          # Build the project
swift run            # Build and run the app
```

No tests exist yet. The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+).

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
