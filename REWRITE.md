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
| 2.5 | Scrollback + drag-drop + activity detection on Metal path | ✅ shipped |
| 2.7 | VT sequence completeness: alt-screen (1049/1047/47), DECTCEM (25), DECSTBM, DECSC/DECRC, expanded keymap (F1-F12, Home/End, PgUp/PgDn, Option+arrow, fn+Delete) | ✅ shipped (27/27 tests green) |
| 2.6 | Flip `useMetalRenderer` default to true; delete SwiftTerm | ⏳ Pending — user dogfood gates the default flip |

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
- **Scrollback**: Rust-side `VecDeque<Vec<Cell>>` per session, hard-capped
  at 5000 lines. `scroll_up` pushes evicted rows; FFI exposes a windowed
  snapshot. `TerminalMTKView.scrollWheel` accumulates trackpad pixels
  into line quanta and composes live+history via
  `MetalTerminalRenderer.uploadScrolled`. Typing snaps back to live view.
- **Drag-and-drop**: `.fileURL` types registered on `TerminalMTKView`;
  dropped paths are written into the PTY space-joined (matches
  `LoggingTerminalView` UX).
- **Activity detection**: `onDirty` / `onIdleTick` callbacks from the
  Metal draw loop invoke `TerminalSession.markActivity()` /
  `.checkIdle()` on the main actor — forward-mode prompt queue drains
  identically to the SwiftTerm path.
- **VT sequence depth (Phase 2.7)**: alternate screen (DECSET 1049/1047/47)
  with full state preservation, cursor visibility (DECTCEM), save/restore
  cursor (DECSC/DECRC, CSI s/u with SGR capture), scrolling region
  (DECSTBM — linefeed + scroll_up bounded, scrollback suppressed for
  in-region scrolls). Claude's interactive UI / vim / less render
  correctly on the Metal path.
- **Keymap depth (Phase 2.7)**: F1–F12 (xterm VT), Home/End, PgUp/PgDn,
  fn+Delete forward, Shift+Tab, Option+arrow → word movement,
  Option+letter → ESC-prefix for bash readline.
- Test coverage: **27 total, all green.** 15 Rust (10 existing
  grid/parser + 5 VT additions) + 12 Swift (3 FFI + 1 scrollback +
  3 Metal pipeline + 5 visibility math).

## Phase 2.6 — flip the default and delete SwiftTerm

All engineering landed. What remains is a user-gated validation pass
and then a sweep.

1. Dogfood the Metal path at scale: `make dev` → Settings → Rendering
   → toggle on. Spawn ~20 Claude/Codex tiles across two project zones.
   Leave running for a few hours. Watch for:
   - Rendering correctness: mid-line SGR changes, ED/EL artifacts,
     cursor position after scroll.
   - Input correctness: bracketed paste, multi-line submissions,
     Ctrl-C, Ctrl-D, arrow keys.
   - Scrollback: trackpad scroll up past a long `claude` log,
     confirm rows back match `~/.local/share/claude/logs/…`.
   - Drag-drop: drop a `.swift` file into a tile, confirm the path
     appears at the cursor.
   - Activity: submit via forward-mode arrow while the target tile is
     busy, confirm the prompt queues and drains after the agent
     finishes.
   - Resource correctness: `lldb` thread list should show ~1 Rust OS
     thread per tile; GPU idle when all tiles are off-screen.
2. Flip the default: `AppSettings.useMetalRenderer = true`.
3. Grep and remove:
   - `import SwiftTerm` in `TerminalNSViewRepresentable.swift` /
     `TerminalSession.swift` / `CanvasView.swift`.
   - `TerminalNSViewRepresentable.swift` — delete the file.
   - `MetalTerminalPreview.swift` — the main canvas is the preview
     now; Cmd+Shift+M menu item goes with it.
   - The `SwiftTerm` dependency in `Package.swift`.
   - `session.terminalView` and `session.isRunning` set-from-SwiftTerm
     callsites in `TerminalManager.swift`.
4. Final pass: bump tests to cover any SwiftTerm-specific behavior
   that became a `TadoCore.Session` behavior in the rewrite (e.g.
   bracketed paste wrapping in `TerminalSession.sendToTerminal`).

Estimated effort post-dogfood: 1 day of cleanup.

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
