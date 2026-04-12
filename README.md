# Tado

A macOS app that turns your todo list into a terminal multiplexer for AI coding agents.

[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- Add a screenshot: ![Tado Screenshot](docs/screenshot.png) -->

## What It Does

Type a task, press Enter, and Tado spawns a terminal running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex](https://openai.com/index/openai-codex/) with your task as the prompt. Every terminal lives as a tile on a pannable, zoomable canvas. Agents can even message each other through a built-in IPC system.

## Features

- **Todo-driven terminal spawning** -- one terminal per task, powered by the AI agent of your choice
- **Pannable/zoomable canvas** -- drag, scroll, and zoom across all your running agents
- **Claude Code and Codex support** -- switch engines from Settings
- **Prompt queueing** -- queue follow-up prompts that auto-send when the agent goes idle
- **Agent-to-agent IPC** -- agents can discover peers and send messages via `tado-send`, `tado-recv`, `tado-list`
- **External CLI tools** -- message any Tado session from an outside terminal
- **Forward mode** -- route your next typed input directly into a specific terminal
- **Activity detection** -- cursor monitoring detects when an agent is idle (5-second threshold)
- **Persistent state** -- todos and settings survive restarts via SwiftData
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

1. Launch Tado and type a task in the input field
2. Press **Enter** -- a terminal tile spawns on the canvas with your AI agent working on it
3. Press **Ctrl+Tab** to switch between the todo list and the canvas
4. **Shift+Scroll** to zoom the canvas, **Scroll** to pan
5. Click the arrow icon on a todo row to enter **forward mode** (your next input goes to that terminal)
6. Press **Cmd+B** to open the sidebar and see all session statuses
7. Press **Cmd+M** to open Settings and change the AI engine or grid layout

### IPC (Inter-Process Communication)

Agents running inside Tado can communicate with each other:

| Command | Description |
|---------|-------------|
| `tado-list` | List all peer sessions with their ID, engine, grid position, and status |
| `tado-send <target> <message>` | Send a message to another session (by name, grid coords like `1,1`, or UUID) |
| `tado-recv [--wait]` | Read messages from the inbox (`--wait` polls for up to 30 seconds) |

From **any external terminal**, you can also use `tado-list` and `tado-send` (installed to `~/.local/bin`) to interact with running Tado sessions.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Enter | Submit todo / send message |
| Ctrl+Tab | Switch between Todo List and Canvas |
| Cmd+M | Open Settings |
| Cmd+B | Toggle Sidebar |
| Shift+Scroll | Zoom canvas |
| Scroll | Pan canvas |

## Architecture

```
Sources/Tado/
  App/          TadoApp (entry point), AppState (UI state)
  Models/       TodoItem, TerminalSession, AppSettings, CanvasLayout, IPCMessage
  Services/     TerminalManager, ProcessSpawner, IPCBroker
  Views/        ContentView, TodoListView, CanvasView, TerminalTileView, SidebarView, SettingsView
```

**State management**: `AppState` and `TerminalManager` are `@Observable` singletons injected via SwiftUI environment. `SwiftData` persists `TodoItem` and `AppSettings`.

**Terminal bridge**: `TerminalNSViewRepresentable` wraps [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s `LocalProcessTerminalView` into SwiftUI. Both views (TodoListView and CanvasView) stay mounted simultaneously via opacity toggling, so terminal processes are never destroyed when switching views.

**IPC**: `IPCBroker` manages a file-based message queue under `/tmp/tado-ipc-<pid>/` with per-session inboxes and outboxes, watched via `DispatchSource`.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE) -- Copyright (c) 2026 Cumulus
