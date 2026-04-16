# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
