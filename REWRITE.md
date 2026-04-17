# Tado Rust+Metal rewrite — status and next steps

Branch: `rewrite/rust-metal-core`. This doc is the source of truth for what
landed vs. what remains. Delete once the rewrite is merged.

## Status at a glance

| Phase | Scope | Status |
|---|---|---|
| 0 | Quick wins in pure Swift (release build, observation granularity, log trim, IPC consolidation, off-main log flush) | ✅ shipped + builds `make build` clean |
| 1 | Rust `tado-core` crate (PTY + VT parser + grid + C FFI) and Swift wrapper | ✅ shipped + tests pass (`make all-test`) |
| 2.1 | Metal shader + glyph atlas + renderer with offscreen test | ✅ shipped — renders synthetic grid to BGRA texture, 6/6 Swift tests green |
| 2.2 | `MetalTerminalView` NSViewRepresentable + keyboard input | ✅ shipped — `TerminalMTKView` subclass with adaptive 30 fps draw loop |
| 2.3 | Debug preview window (Cmd+Shift+M) exercising the new pipeline on a real `zsh` | ✅ shipped — accessible from Debug menu |
| 2.4 | Swap `MetalTerminalView` into `TerminalTileView`, delete SwiftTerm | ⏳ Pending — see step-by-step below |
| 3 | Canvas virtualization (only visible tiles mount GPU resources) | ⏳ Not started |

## What works today on this branch

- `swift run -c release` (via `make dev`) — 5–10× faster startup than the
  debug default.
- Activity-timer churn no longer invalidates the canvas `ForEach`.
  `lastActivityDate`, `lastKnownCwd`, and `logBuffer` are `@ObservationIgnored`.
- `logBuffer` cannot grow past 256 KB (ring-buffer trim in `appendLog`).
- Log flush file I/O runs on `DispatchQueue.global(qos: .utility)`, not main.
- One 3 s fallback poller in `IPCBroker` instead of three.
- `tado-core` Rust crate: `cargo test --release` green, linked as a
  static library into the Swift executable.
- `TadoCore.Session` Swift wrapper: 3 real-PTY tests green (`swift test`).
  Spawns `/bin/echo`, `/bin/sh`, `/bin/cat`; writes, reads dirty diffs.
- **Metal renderer (Phase 2)**: `Sources/Tado/Rendering/` has a full
  pipeline — Metal shader, CoreText glyph atlas, `MetalTerminalRenderer`,
  `MetalTerminalView` NSViewRepresentable with keyboard input. Render loop
  throttles to ~4 fps when idle, 30 fps when active.
- **Debug preview**: `Cmd+Shift+M` (Debug → Metal Terminal Preview) opens
  a standalone window that spawns `/bin/zsh -l` via `TadoCore.Session`
  and renders it with the new pipeline. Exercises every layer end-to-end
  without touching the SwiftTerm canvas. This is how to try the rewrite
  today: `make dev` → `Cmd+Shift+M`.
- Test coverage: 11 total, all green. 5 Rust (grid/VT parser/colors) +
  6 Swift (3 FFI round-trip through `/bin/echo`/`sh`/`cat`, 3 Metal
  pipeline incl. offscreen pixel verification).

## Phase 2.4 — swap `MetalTerminalView` into `TerminalTileView`

Phases 2.1–2.3 landed. What remains to go from "preview window works" to
"main canvas runs on Metal":

1. Add `var core: TadoCore.Session?` to `TerminalSession`
   (`Sources/Tado/Models/TerminalSession.swift`). Populate at spawn
   time in `TerminalManager.spawnSession` — alongside the existing
   SwiftTerm path until the swap is complete, so regressions surface
   gradually.
2. In `TerminalTileView` (`Sources/Tado/Views/TerminalTileView.swift`),
   replace `TerminalNSViewRepresentable(session: …)` with:
   ```swift
   if let core = session.core {
       MetalTerminalView(session: core, cols: 80, rows: 24)
   }
   ```
   Keep the SwiftTerm branch as a feature-flag fallback for one release.
3. Grep for remaining SwiftTerm surface and rewire:
   - `session.terminalView?.send(…)` → `session.core?.write(…)`
   - `LocalProcessTerminalView`, `LoggingTerminalView` references
   - `getTerminal().buffer.x/y` (activity timer) → consume
     `session.core?.snapshotDirty()?.cursorX/Y` instead
4. Delete once the feature flag graduates:
   - `Sources/Tado/Views/TerminalNSViewRepresentable.swift`
   - `Sources/Tado/Rendering/MetalTerminalPreview.swift` (the preview
     window was a stepping stone)
   - `SwiftTerm` dep in `Package.swift`
5. File drop handling: port `LoggingTerminalView.performDragOperation`
   to `TerminalMTKView` (register `.fileURL` dragged types, write
   space-separated paths to `session.write`).

Estimated effort: 3–5 days. The hardest bit is the cursor/activity path —
Phase 0 already made `lastActivityDate` observation-ignored; consume
`snapshotDirty().dirtyRows.isEmpty` as the new "is idle" signal.

## Phase 3 — canvas virtualization (~1 week)

In `CanvasView.swift`:
1. Compute the visible tile set each pan/zoom end (not per frame).
   Visible rect = `windowBounds / scale - offset`. Tile center inside
   that rect (with a small margin) == visible.
2. `TerminalTileView` becomes a lightweight shell; it only instantiates
   `MetalTerminalView` when `isVisible == true`. Off-screen tiles
   render a cheap `RoundedRectangle` placeholder.
3. `TadoCore.Session` keeps running in the background for all tiles —
   the cost is a Rust OS thread per session (cheap) and the cell grid
   memory (~80 KB per 80×24 tile, negligible).
4. Panning/zooming debounce already exists at `CanvasView.swift:513`;
   extend `isPanning` to flip a `MetalTerminalView.interactive` flag
   that disables subpixel AA while panning.

## Verification plan per phase

- **After Phase 2.1**: standalone `make core && make build`; the
  glyph atlas unit test renders `"Hello"` to an offscreen texture and
  compares pixel hashes.
- **After Phase 2.3**: spin up app, spawn 5 terminals. Confirm
  keystrokes reach Rust, output renders via Metal. Activity Monitor:
  app < 8% idle CPU. `MTL_HUD_ENABLED=1` shows <6 ms frame time.
- **After Phase 2.4**: regression sweep — `tado-send`, forward mode,
  dispatch modal, theme switch, scrollback via trackpad, drag-drop
  onto a tile. Each should behave identically to today.
- **After Phase 3**: `for i in {1..100}; do tado-deploy "sleep 3600"; done`.
  Pan to any tile, verify the off-screen tiles don't consume GPU.
  Idle CPU < 15%, memory < 2 GB, pan/zoom at 60 fps.

## Notes for the next agent session

- The Rust tests are the contract. Don't change `TadoCell` layout
  without also updating the `const _: () = { assert!(...) }` in
  `tado-core/src/ffi.rs` and the Swift `TadoCore.Cell` struct.
- `snapshot_dirty()` clears the dirty flags as a side effect — only
  call it from the renderer, not from debug inspection code, or the
  renderer will miss rows.
- The reader thread model in `tado-core/src/session.rs` is
  one-OS-thread-per-session. That's fine for 100 tiles on macOS;
  if profiling shows thread overhead at 200+ tiles, swap to a
  `kqueue` coalescer. Don't move to tokio — tokio can't truly async
  a blocking PTY read, and the thread model is simpler.
- Metal renderer must use `CADisplayLink` / `CVDisplayLink`, not
  per-tile `Timer`s. The whole point of the rewrite is one wake-up
  source for N tiles.
