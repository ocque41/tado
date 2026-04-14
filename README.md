# Tado

A macOS app that turns your todo list into a terminal multiplexer for AI coding agents.

[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- Add a screenshot: ![Tado Screenshot](docs/screenshot.png) -->

## What It Does

Type a task, press Enter, and Tado spawns a terminal running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex](https://openai.com/index/openai-codex/) with your task as the prompt. Every terminal lives as a tile on a pannable, zoomable canvas. Agents can even message each other through a built-in IPC system.

## Features

- **Projects** -- organize todos under a directory; agents are auto-discovered from `.claude/agents/` and `.codex/agents/`
- **Teams** -- group agents into named teams for coordinated multi-agent work
- **Todo-driven terminal spawning** -- one terminal per task, powered by the AI agent of your choice
- **Pannable/zoomable canvas** -- drag, scroll, and zoom across all your running agents
- **Resizable and moveable tiles** -- drag edges to resize, drag title bar to reposition
- **Claude Code and Codex support** -- switch engines from Settings
- **Mode and effort settings** -- configure permission mode and thinking/reasoning effort per engine
- **Prompt queueing** -- queue follow-up prompts that auto-send when the agent goes idle
- **MCP Server** -- `tado-mcp` exposes A2A tools to any MCP-compatible AI agent; auto-registered on launch
- **Agent-to-agent IPC** -- agents can discover peers, read output, broadcast, and send messages via CLI tools
- **Pub/sub topics** -- `tado-publish`, `tado-subscribe`, `tado-unsubscribe` for topic-based messaging
- **Project bootstrap** -- one-click injection of A2A docs and team structure into any project's CLAUDE.md/AGENTS.md
- **`tado-deploy`** -- agents can spawn other agents on the canvas programmatically; engine auto-detected from agent source
- **Multiline input with renaming** -- grow-to-fit editor with Cmd+Enter submit; right-click todos to rename
- **External CLI tools** -- message any Tado session from an outside terminal
- **Forward mode** -- route your next typed input directly into a specific terminal
- **Done and Trash lists** -- move completed or discarded todos out of the main list
- **Activity detection** -- cursor monitoring detects when an agent is idle (5-second threshold)
- **Persistent state** -- todos, projects, teams, and settings survive restarts via SwiftData
- **Session sidebar** -- live status indicators for all running sessions

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+ / Xcode 15.3+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI and/or [Codex](https://github.com/openai/codex) CLI installed and available on your `PATH`

## Building

```bash
git clone https://github.com/ocque41/tado.git
cd tado
swift build
swift run
```

No Xcode project is included. The project uses Swift Package Manager as its build system. You can also open `Package.swift` directly in Xcode.

## Usage

1. Launch Tado and type a task in the input field (multiline supported, grows up to 8 lines)
2. Press **Cmd+Enter** (`⌘↩`) -- a terminal tile spawns on the canvas with your AI agent working on it
3. Press **Ctrl+Tab** to cycle between Todos, Canvas, Projects, and Teams
4. **Shift+Scroll** to zoom the canvas, **Scroll** to pan
5. Click the arrow icon on a todo row to enter **forward mode** (your next input goes to that terminal)
6. Press **Cmd+B** to open the sidebar and see all session statuses
7. Press **Cmd+M** to open Settings and change the AI engine or grid layout

### IPC (Inter-Process Communication)

Agents running inside Tado can communicate with each other:

| Command | Description |
|---------|-------------|
| `tado-list [--project X] [--team Y]` | List all peer sessions, optionally filtered by project or team |
| `tado-read <target> [--tail N] [--follow] [--raw]` | Read terminal output from a session |
| `tado-send [--project X] <target> <message>` | Send a message to another session (by name, grid coords like `1,1`, or UUID) |
| `tado-deploy "<prompt>" [--agent N] [--team T] [--project P] [--engine E] [--cwd D]` | Spawn a new agent session on the canvas |
| `tado-broadcast [--project X] [--team Y] <message>` | Send a message to all matching sessions |
| `tado-recv [--wait]` | Read messages from the inbox (`--wait` polls for up to 30 seconds) |
| `tado-publish <topic> <message>` | Publish a message to a topic |
| `tado-subscribe <topic>` | Subscribe the current session to a topic |
| `tado-unsubscribe <topic>` | Unsubscribe from a topic |
| `tado-topics` | List all active topics and their subscribers |
| `tado-team` | List teammates in the current session's team |

From **any external terminal**, CLI tools are installed to `~/.local/bin`. The **tado-mcp** MCP server is also auto-registered so MCP-compatible agents can use Tado tools natively.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Enter | Submit todo / send message |
| Right-click on todo | Context menu (Rename, Mark as Done, Move to Trash) |
| Ctrl+Tab | Cycle through Todos, Canvas, Projects, Teams |
| Cmd+M | Open Settings |
| Cmd+B | Toggle Sidebar |
| Cmd+D | Done list |
| Cmd+T | Trash list |
| Shift+Scroll | Zoom canvas |
| Scroll | Pan canvas |

## Architecture

```
tado-mcp/         TypeScript MCP server (list, read, send, broadcast tools)
Sources/Tado/
  App/          TadoApp (entry point), AppState (UI state)
  Models/       TodoItem, TerminalSession, AppSettings, CanvasLayout, IPCMessage, Project, Team, AgentDefinition
  Services/     TerminalManager, ProcessSpawner, IPCBroker, AgentDiscoveryService
  Views/        ContentView, TodoListView, DoneListView, TrashListView, CanvasView, ProjectsView, TeamsView, TerminalTileView, SidebarView, SettingsView
```

**State management**: `AppState` and `TerminalManager` are `@Observable` singletons injected via SwiftUI environment. `SwiftData` persists `TodoItem`, `Project`, `Team`, and `AppSettings`.

**Terminal bridge**: `TerminalNSViewRepresentable` wraps [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s `LocalProcessTerminalView` into SwiftUI. All four page views stay mounted simultaneously via opacity toggling, so terminal processes are never destroyed when switching views.

**Agent discovery**: `AgentDiscoveryService` scans a project's `.claude/agents/` and `.codex/agents/` directories for `.md` agent definition files, making them available for team assignment and todo routing.

**IPC**: `IPCBroker` manages a file-based message queue under `/tmp/tado-ipc-<pid>/` with per-session inboxes, outboxes, and a pub/sub topics directory, watched via `DispatchSource`.

**MCP Server**: `tado-mcp/` is a TypeScript MCP server built on `@modelcontextprotocol/sdk` that exposes `tado_list`, `tado_read`, `tado_send`, and `tado_broadcast` as MCP tools. Auto-registered in `~/.claude.json` on app launch.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE) -- Copyright (c) 2026 Cumulus
