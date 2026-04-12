# Contributing to Tado

Thanks for your interest in contributing! This document covers everything you need to get started.

## Code of Conduct

This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you agree to uphold it. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Development Setup

```bash
git clone https://github.com/ocque41/tado.git
cd tado
swift build
swift run
```

**Requirements**: macOS 14+, Swift 5.10+ / Xcode 15.3+

No Xcode project is included. You can open `Package.swift` directly in Xcode, or build from the command line with SPM.

## Project Structure

```
Sources/Tado/
  App/          TadoApp (entry point), AppState (UI state)
  Models/       TodoItem, TerminalSession, AppSettings, CanvasLayout, IPCMessage
  Services/     TerminalManager, ProcessSpawner, IPCBroker
  Views/        ContentView, TodoListView, CanvasView, TerminalTileView, SidebarView, SettingsView
```

## How to Contribute

1. **Open an issue first** for non-trivial changes so we can discuss the approach
2. Fork the repository and create a feature branch from `master`
3. Make your changes, keeping PRs focused (one concern per PR)
4. Ensure `swift build` succeeds
5. Submit a pull request with a description of what changed and why

## Code Style

- Standard Swift conventions
- `@Observable` + `@MainActor` for state classes
- SwiftUI views are structs
- Monospaced fonts (SF Mono / Menlo) for all UI text

## Testing

No test suite exists yet. Contributions adding tests are especially welcome! If you add tests, use Swift Testing or XCTest and ensure they pass with `swift test`.

## Questions?

Open an issue or start a discussion.
