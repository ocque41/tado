# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
