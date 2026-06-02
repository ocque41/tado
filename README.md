# Tado

1. Desktop application that turns your todo list into a terminal multiplexer of coding agents.

2. Tado `npm i @tt0/tado` is a Codex-first orchestration system

The public terminal package is `@tt0/tado`. It ships prebuilt Rust binaries,
starts a local profile daemon, and gives Codex a terminal workspace with
sessions, transcripts, projects, Kanban, events, and MCP/A2A tools.

```bash
npx @tt0/tado
# or
npm install -g @tt0/tado
tado
```

## Terminal Agent OS

- `codex` is the only public AI provider in the terminal package.
- `shell` and `raw` remain terminal utility session kinds.
- Agent definitions are read from `.codex/agents/`.
- Runtime profiles keep non-secret provider preferences: model, reasoning
  effort, permission mode, alternate-screen behavior, and account label.
- The default account label is `default` and uses the user's existing Codex CLI
  authentication. Tado does not store Codex tokens.
- Rust `tado-mcp` is the release MCP bridge. The legacy Node MCP package is
  private/reference-only.

The npm package installs:

```text
tado
tadod
tado-list
tado-read
tado-send
tado-events
tado-deploy
tado-bootstrap
tado-kanban
tado-eternal
tado-dispatch
tado-mcp
tado-projects
tado-system
```

## Requirements

- macOS 14 or later.
- Node.js 18 or later for the npm launcher.
- Rust stable for source builds.
- Swift 5.10+ / Xcode 15.3+ for the desktop app.
- Codex CLI installed and authenticated for Codex sessions.

## Build From Source

```bash
git clone https://github.com/ocque41/tado.git
cd tado
swift build
cd tado-core && cargo test -p tado-runtime -p tado-cli -p tado-mcp
```

Build release binaries for the npm package:

```bash
cd tado-core
cargo build --release -p tado-runtime --bin tadod -p tado-cli --bins -p tado-mcp --bin tado-mcp
cargo build --release --target x86_64-apple-darwin -p tado-runtime --bin tadod -p tado-cli --bins -p tado-mcp --bin tado-mcp
```

## Runtime Basics

```bash
tado --help
tado daemon status
tado project add ~/Code/my-app --name my-app
tado project use my-app
tado spawn --engine codex "implement the next task"
tado list
tado read <session>
tado send <session> "follow-up prompt"
```

In the TUI:

- `/codex <prompt>` spawns a Codex session.
- `/spawn <command>` spawns a shell utility PTY.
- `/project` and `/projects` manage profile projects.
- `Shift+X` kills and deletes the selected runtime session.
- Settings is an interactive list, not raw JSON.

## Repository Map

- `npm/tado/` - public npm package for `@tt0/tado`.
- `tado-core/crates/tado-runtime/` - profile daemon, runtime protocol, SQLite
  session/transcript store, PTY ownership, and Agent OS API.
- `tado-core/crates/tado-cli/` - `tado`, helper CLIs, workflow CLIs, and TUI.
- `tado-core/crates/tado-mcp/` - Rust MCP bridge for runtime A2A tools.
- `tado-core/crates/bt-core/` and `dome-mcp/` - Dome knowledge backend.
- `Sources/Tado/` - macOS SwiftUI desktop app.

## Release Notes

See [CHANGELOG.md](CHANGELOG.md) and [npm/tado/CHANGELOG.md](npm/tado/CHANGELOG.md).

## License

[MIT](LICENSE) -- Copyright (c) 2026 Cumulus
