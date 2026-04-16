# Tado Rust+Metal rewrite — status and next steps

Branch: `rewrite/rust-metal-core`. This doc is the source of truth for what
landed vs. what remains. Delete once the rewrite is merged.

## Status at a glance

| Phase | Scope | Status |
|---|---|---|
| 0 | Quick wins in pure Swift (release build, observation granularity, log trim, IPC consolidation, off-main log flush) | ✅ shipped + builds `make build` clean |
| 1 | Rust `tado-core` crate (PTY + VT parser + grid + C FFI) and Swift wrapper | ✅ shipped + tests pass (`make all-test`) |
| 1b | Replace SwiftTerm in the running app with `TadoCore.Session` | ⏸ Deferred — joined with Phase 2 (see below) |
| 2 | Metal glyph atlas + renderer replacing `LoggingTerminalView` | ⏳ Not started |
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

## Why Phase 1b was deferred into Phase 2

The plan originally had Phase 1 finish with the running app wired to Rust
while still rendering through `SwiftTerm`. That requires a Swift adapter
that feeds `Rust GridDiff` back into `SwiftTerm.Terminal`'s `feed(...)` —
essentially running two VT parsers in sequence (Rust parses → reconstruct
ANSI output → SwiftTerm re-parses). That adapter is ~1 week of fiddly
work, then gets thrown away the moment the Metal renderer lands.

**Recommendation**: Do Phase 1b and Phase 2 together. The Metal renderer
consumes `TadoCore.Snapshot` directly; no `SwiftTerm` adapter needed.

## Phase 2 — step-by-step

All files live under `Sources/Tado/Rendering/` (new directory).

### 2.1 Metal shader + glyph atlas (~2–4 days)

1. `Shaders.metal`: one vertex + fragment pair. Vertex expands a single
   per-cell quad (position from `(col, row)` instance id, UV into the
   glyph atlas). Fragment samples the atlas, multiplies by fg color,
   blends over bg. Keep this shader under 50 lines for Phase 2.
2. `GlyphAtlas.swift`: owns a single `MTLTexture` (start 2048×2048 R8).
   Uses `CTFontCreatePathForGlyph` + `CGContext` to rasterize a glyph
   on demand, packs into a shelf allocator, returns `(u0, v0, u1, v1)`.
   LRU-evict least-recently-used glyphs when the atlas is full.
3. `FontMetrics.swift`: measures cell size for a given `CTFont` at a
   given size. Tado uses SF Mono 13pt (see
   `TerminalNSViewRepresentable.swift:91`).

### 2.2 `MetalTerminalRenderer` (~3–5 days)

1. `MetalTerminalRenderer.swift`: owns the `MTLDevice`, command queue,
   pipeline state, vertex/uniform buffers. One instance per window;
   multiple tiles share it.
2. Per-tile state: ring of `MTLBuffer`s sized `cols * rows` cells for
   triple-buffering (avoid GPU/CPU races). `upload(snapshot:)` memcpys
   dirty rows into the current buffer slot.
3. `draw(in: MTKView, tiles: [Tile])`: one `MTLRenderCommandEncoder`
   per frame, one `drawIndexedPrimitives(instanceCount: cols*rows)`
   per visible tile. Cell-quad geometry is a static shared index buffer.

### 2.3 `MetalTerminalView` NSViewRepresentable (~2 days)

1. Wraps `MTKView`. `makeNSView` creates the view, sets delegate to
   a `Coordinator` that owns the `MetalTerminalRenderer` reference.
2. `Coordinator.draw(in:)` pulls `session.core.snapshotDirty()`,
   calls `renderer.upload(...)`, `renderer.draw(...)`.
3. Keyboard input: override `performKeyEquivalent(with:)` + set
   `acceptsFirstResponder = true`; translate `NSEvent` → UTF-8 bytes
   → `session.core.write(_:)`. Reuse the existing
   `LoggingTerminalView.performKeyEquivalent` logic as a reference.
4. Mouse: translate SwiftUI coords via
   `convert(event.locationInWindow, from: nil)` → cell coords.
   Phase 2 can skip mouse reporting (`DECSET 1000`); Phase 3
   adds it.

### 2.4 Swap into `TerminalTileView` (~1 day)

Replace `TerminalNSViewRepresentable(session: …)` call sites with
`MetalTerminalView(session: …)`. Delete:
- `Sources/Tado/Views/TerminalNSViewRepresentable.swift`
- `SwiftTerm` dep in `Package.swift`

Grep for remaining `SwiftTerm`, `LocalProcessTerminalView`,
`LoggingTerminalView`, `session.terminalView` references and rewire to
`session.core` (the `TadoCore.Session`).

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
