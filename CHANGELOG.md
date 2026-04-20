# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
