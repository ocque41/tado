# Tado Rust+Metal rewrite — status and next steps

Branch: `rewrite/rust-metal-core`. This doc is the source of truth for what
landed vs. what remains. Delete once the rewrite is merged.

## Status at a glance

| Phase | Scope | Status |
|---|---|---|
| 0 | Quick wins in pure Swift (release build, observation granularity, log trim, IPC consolidation, off-main log flush) | ✅ shipped |
| 1 | Rust `tado-core` crate (PTY + VT parser + grid + C FFI) and Swift wrapper | ✅ shipped |
| 2.1 | Metal shader + glyph atlas + renderer with offscreen test | ✅ shipped |
| 2.2 | `MetalTerminalView` NSViewRepresentable + keyboard input | ✅ shipped |
| 2.3 | Debug preview window (Cmd+Shift+M) | ✅ shipped |
| 2.4 | Feature-flag Metal path in `TerminalTileView` (Settings → Rendering) | ✅ shipped |
| 3 | Canvas virtualization — off-screen tiles shed GPU resources; Rust PTY keeps running | ✅ shipped |
| 2.5 | Graduate the flag: delete SwiftTerm dep once Metal path proves stable | ⏳ Pending — gated on user trial at scale |

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
  and renders it with the new pipeline. Non-destructive try-before-you-flip.
- **Production toggle**: Settings → Rendering → "Use Rust + Metal renderer".
  Per-session decision frozen at spawn; flipping the flag affects only
  future tiles. Ship with the flag off; users opt in.
- **Canvas virtualization (Phase 3)**: `TileVisibility` computes the
  visible world rect from scale+offset+viewport (+ one tile width of
  margin). Off-screen Metal tiles render a cheap placeholder rectangle;
  their `TadoCore.Session` keeps streaming PTY output in Rust, so
  re-mounting on pan-in picks up live state.
- Test coverage: **16 total, all green.** 5 Rust (grid/VT parser/colors) +
  11 Swift (3 FFI round-trip through `/bin/echo`/`sh`/`cat`, 3 Metal
  pipeline incl. offscreen pixel verification, 5 visibility math).

## Phase 2.5 — graduate the feature flag

Everything is on the branch. The only remaining decision is when to
remove the SwiftTerm fallback. Pre-requisites before flipping the
default and deleting SwiftTerm:

1. Dogfood the Metal path at scale: `make dev` → Settings → Rendering
   → on. Spawn ~20 Claude/Codex tiles across two project zones. Leave
   running for a few hours. Watch for:
   - Rendering correctness: mid-line SGR changes, ED/EL artifacts,
     cursor position after scroll.
   - Input correctness: bracketed paste, multi-line submissions,
     Ctrl-C, Ctrl-D, arrow keys.
   - Resource correctness: `lldb` thread list should show ~1 Rust OS
     thread per tile; GPU idle when all tiles are off-screen.
2. Port three edges of `LoggingTerminalView` missing from
   `TerminalMTKView`:
   - File drag-drop (`registerForDraggedTypes([.fileURL])`); write
     space-separated paths to `coreSession.write`.
   - Trackpad scrollback (today's `scrollUpLines`/`scrollDownLines`
     hooks feed SwiftTerm's internal scrollback; Metal path needs a
     Rust-side scroll buffer — extend `tado-core::grid` with an
     optional scrollback deque).
   - Tile activity detection: today's `TerminalManager.tickActivity`
     reads `SwiftTerm.Terminal.buffer.x/y`. Replace with
     `session.coreSession?.snapshotFull()?.cursorX/Y` or, cheaper,
     `snapshotDirty().dirtyRows.isEmpty` as "is idle".
3. Flip the `AppSettings.useMetalRenderer` default to `true`.
4. Grep and remove:
   - `import SwiftTerm` in `TerminalNSViewRepresentable.swift` /
     `TerminalSession.swift` / `CanvasView.swift`.
   - `TerminalNSViewRepresentable.swift` — delete the file.
   - `MetalTerminalPreview.swift` — it was a stepping stone; the
     main canvas is the preview now.
   - The `SwiftTerm` dependency in `Package.swift`.
   - `session.terminalView` and `session.isRunning` set-from-SwiftTerm
     callsites in `TerminalManager.swift`.

Estimated effort for items 2 and 4: 2–3 days. The scrollback buffer
is the biggest single piece — extending `tado_core::grid::Grid` with
a bounded `VecDeque<Vec<Cell>>` for off-top rows and exposing a
`scroll_snapshot(start_row, height)` FFI.

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
