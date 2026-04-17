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
| 2.7 | VT sequence completeness: alt-screen (1049/1047/47), DECTCEM (25), DECSTBM, DECSC/DECRC, expanded keymap (F1-F12, Home/End, PgUp/PgDn, Option+arrow, fn+Delete) | ✅ shipped |
| 2.8 | Bracketed paste (DECSET 2004 + Cmd+V) · OSC 0/2 window title → `TerminalSession.title` · mouse button reporting (DECSET 1000/1006) | ✅ shipped |
| 2.9 | Glyph lookup correctness: renderer rebuilds the GPU lookup when the atlas mutates, not only when `lookupMax` grows. Fixed latent first-frame-blank bug, extended coverage to Latin-1 + full BMP for ASCII-dense workloads. | ✅ shipped |
| 2.10 | `TerminalTheme` propagates to Metal: `set_default_colors` sets the palette + retints factory-blank cells; `MTKView.clearColor` matches the tile bg. Randomized tile themes look identical between SwiftTerm and Metal renderers. | ✅ shipped |
| 2.11 | Text selection + Cmd+C copy: click-drag selection, shader-side fg/bg swap highlight, pure-function `TerminalTextExtractor` with unit tests, NSPasteboard copy. | ✅ shipped |
| 2.12 | Application cursor mode (DECCKM, DECSET 1) so vim/less arrow remaps work; bell (0x07) → NSSound.beep with per-tick coalescing. Typed-slot event drain replacing the generic `GridEvent` queue. | ✅ shipped |
| 2.13 | `AppSettings.terminalFontSize` (9–24pt) threaded through the whole render stack; Settings UI gains a stepper. Existing tiles keep their current metrics on setting change. | ✅ shipped |
| 2.14 | Wide-char support (East-Asian Wide via `unicode-width`): 2-cell cells with `ATTR_WIDE` / `ATTR_WIDE_FILLER`; shader extends wide-start quad and skips filler; atlas rasterizes at 2× cell width; text extractor skips filler. CJK + wide box-drawing align correctly. | ✅ shipped |
| 2.15 | ANSI palette theming: Grid carries a 16-slot palette consulted by SGR 30..=37/40..=47/90..=97/100..=107 + xterm-256 slots 0..15. Solarized / Dracula / Nord / Monokai / Tokyo Night themes ship canonical palettes; others keep the baked-in default. | ✅ shipped |
| 2.16 | Blinking cursor on Metal path (~530 ms Terminal.app cadence). Activity resets the phase so the cursor doesn't disappear during typing. Toggle in Settings → Rendering → "Blink cursor". | ✅ shipped |
| 2.17 | Configurable bell mode (Off / Audible / Visual / Both). Visual bell flashes the tile at 35% white for 150 ms. Accessibility win for muted-audio workflows. | ✅ shipped |
| 2.18 | Glyph atlas overflow recovery: on shelf exhaustion, reset + retry; default size bumped 2048² → 4096² (~4× capacity). modCount bump already triggers GPU lookup rebuild. | ✅ shipped (47/47 tests green) |
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
- **Bracketed paste + Cmd+V (Phase 2.8)**: `DECSET 2004` wires into
  `TadoCore.Session.bracketedPasteEnabled`; `TerminalMTKView.paste(_:)`
  wraps clipboard content with `ESC [ 200 ~ ... ESC [ 201 ~` when it's
  on. Cmd+V is intercepted in `performKeyEquivalent`.
- **OSC titles (Phase 2.8)**: Rust accumulates `GridEvent::TitleChanged`
  during byte processing; `TerminalMTKView` drains `session.takeTitle()`
  at 1 Hz alongside the idle probe and calls `onTitleChange`. Wired to
  `TerminalSession.title` so the tile titlebar updates as the agent
  reports a new title.
- **Mouse reporting (Phase 2.8)**: DECSET 1000/1002/1006 tracked in the
  grid; `TerminalMTKView` emits SGR-encoded button events on left/right
  click/release. Legacy encoding silent-dropped (can't represent cols
  > 95).
- **Glyph lookup correctness (Phase 2.9)**: `GlyphAtlas.modCount` bumps
  on every new rect insertion; `MetalTerminalRenderer` rebuilds the GPU
  lookup when the atlas mutates (not only when the codepoint bound
  grows). Fixes a first-frame-blank bug where freshly rasterized ASCII
  would render as pure background. Lookup bound rounded up to 256-code-
  point boundaries to avoid per-char thrashing; capped at 0x10000 (BMP).
- **Theme mapping (Phase 2.10)**: `TerminalTheme.{foregroundRGBA,backgroundRGBA}`
  pack NSColor → sRGB → 0xRRGGBBAA. `set_default_colors` updates the
  palette and retints any "factory-blank" cells that haven't been
  written yet; `MTKView.clearColor` mirrors the tile bg. Per-tile
  random themes render identically under both renderers.
- **Selection + Cmd+C copy (Phase 2.11)**: click-drag tracks cell
  coords; shader swaps fg/bg on selected cells (same inversion the
  cursor already uses). `TerminalTextExtractor.extract(from:start:end:)`
  is a pure function over `TadoCore.Snapshot` — unit-testable without a
  PTY. Zero-width click selections clear and pass through to mouse
  reporting; drags stay highlighted and suppress the PTY click.
- **Application cursor + bell (Phase 2.12)**: DECSET 1 (DECCKM) flips
  arrows + Home/End between CSI (`ESC [ A`) and SS3 (`ESC O A`)
  prefixes so vim/less arrow keybindings work. BEL (0x07) routes
  through a typed `bell_count: AtomicU32` slot on Session; the draw
  loop rings `NSSound.beep` once per non-zero drain. Event-drain
  refactored from a generic `GridEvent` queue to typed slots
  (`latest_title`, `bell_count`) so take operations don't compete.
- Test coverage: **41 total, all green.** 21 Rust + 20 Swift.

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
