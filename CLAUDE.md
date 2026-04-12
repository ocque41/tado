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
```

**Typical workflow for responding to a terminal:** `tado-read 1,1` to see what it output, then `tado-send 1,1 "your response"` to reply.

**IPC internals:** File-based via `/tmp/tado-ipc/`. Each session has `inbox/`, `outbox/`, and `log` in its directory. Terminal output is flushed to the `log` file every 5 seconds. External messages go to `/tmp/tado-ipc/a2a-inbox/`. See `IPCBroker.swift` and `IPCMessage.swift`.

## Key Files

- `ProcessSpawner.swift` — Builds the CLI command for the selected engine
- `TerminalNSViewRepresentable.swift` — NSViewRepresentable bridge + activity monitoring Coordinator
- `TerminalSession.swift` — Session model with status FSM and prompt queue
- `CanvasLayout.swift` — Grid position math and tile dimensions
- `IPCBroker.swift` — File-based IPC broker, a2a inbox watcher, CLI tool generation
- `IPCMessage.swift` — IPC message model and registry types
