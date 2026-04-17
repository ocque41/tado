# Tado Rust+Metal Rewrite — Performance Baselines

Quantitative numbers backing the "100+ tiles, idle CPU < 15%" claim.
Each section notes what machine + commit + mode the numbers came from,
so regressions show up when someone reruns on a comparable system.

## Microbenchmarks (automated)

### Rust core — `cargo bench --bench grid_bench`

Machine: M4, 32 GB RAM, macOS 25.3.0
Commit: `rewrite/rust-metal-core` @ Phase 2.22 landing
Command: `make core-bench`

| Benchmark | Time (median) | Notes |
|---|---|---|
| `grid_write_throughput / vt_1mib_into_100x40_grid` | **15.857 ms** | Full range [15.099 ms .. 16.836 ms] |
|   throughput | **63.065 MiB/s** | Enough to absorb one tile's second-worth of output in ~16 ms; 60 tiles fit in a 16 ms frame budget at full throttle |
| `snapshot_dirty_one_row` | **48.676 ns** | Range [45.304 ns .. 53.726 ns]; effectively free on the per-frame path |

**Reading these numbers**: the Rust core is *not* the bottleneck for 100+
tiles. Ingesting 1 MB of mixed-SGR VT output in ~16 ms means a single
thread can feed ~60 tiles' worth of synthetic-burst output inside one
60 fps frame budget. In practice Rust cores sit idle most of the time;
the numbers matter as a regression tripwire.

### Swift Metal renderer — `swift test --filter RendererBenchTests`

Machine: M4, 32 GB RAM, macOS 25.3.0
Commit: `rewrite/rust-metal-core` @ Phase 2.22 landing
Command: `make bench` (the Rust bench runs first, then these)

| Benchmark | Mean time (10 iter) | Steady-state (excl. warmup) | Notes |
|---|---|---|---|
| `testRenderOffscreen_80x24_dense` | **2 ms** | ~0.8–1.3 ms | Typical terminal size, all cells lit. First iteration is a ~7 ms shader-compile warmup; steady-state is ~1 ms per frame |
| `testRenderOffscreen_200x50_dense` | **3 ms** | ~1.7–2.0 ms | 10 000 cells — rules out O(n²) regressions |
| `testRenderOffscreen_freshGlyphsEveryFrame` | **63 ms** | 30–100 ms | Worst case: every frame forces atlas+lookup rebuild. Not a realistic steady-state, but bounds the cost of a font-switch or theme swap |

**Reading these numbers**: at ~1 ms per 80×24 frame the renderer can
sustain ~1000 fps single-threaded. With 100 tiles rendered
sequentially per frame at 60 fps we'd need ~16.6 ms / 100 = 0.17 ms
per tile — the 0.8 ms we measure is ~4× over that target, meaning the
renderer *won't* hit 100 tiles at 60 fps in a naive "redraw every
tile every frame" loop. The actual scalability comes from canvas
virtualization (Phase 3): off-screen tiles skip the GPU pass entirely,
so the number of GPU-active tiles equals visible-on-canvas, which
for a pannable/zoomable view is bounded by screen real estate (typically
<10 tiles visible at once).

Swift XCTest prints raw timings in its output; mean / stddev shown
above came from running `make bench` at Packet C landing.

## End-to-end stress (manual, dogfood-tier)

### `bench/100-tile-stress.sh`

Spawns 100 tiles; each runs `yes | head -n 200000 && sleep 3600` so the
renderer + Rust core see a synchronized bursts-of-VT workload without
paying for real Claude API calls. Not part of automated CI.

**Usage**:
1. Start Tado: `make dev`.
2. In a separate shell: `bash bench/100-tile-stress.sh`.
3. In a third shell, run the measurement commands the script prints.

**Comparing SwiftTerm vs Metal**: while both paths still exist (pre
Packet E), toggle Settings → Rendering → "Use Rust + Metal renderer"
and rerun the script to capture both sides of the table below.

| Measurement | SwiftTerm (baseline) | Metal (rewrite) |
|---|---|---|
| Idle CPU % after 2 min | _tbd_ | _tbd_ |
| `top` thread count | _tbd_ | _tbd_ |
| `powermetrics -s thermal` (°C) | _tbd_ | _tbd_ |
| Frame time (MTL HUD) | _tbd_ | _tbd_ |

**Target**: Metal path should show dramatically lower idle CPU once
off-screen tiles shed their GPU work via canvas virtualization
(Phase 3 shipped). If Metal numbers don't beat SwiftTerm by at least
2× on idle CPU for 20+ tiles, investigate before Packet E deletes the
fallback.

## Rerunning

```bash
make core-bench      # Rust microbenches only (~30s)
make bench           # Rust + Swift renderer measures (~1 min)
bash bench/100-tile-stress.sh   # Manual stress harness
```

Append new numbers as dated sections here when rerunning (don't
overwrite — keeping the history makes regressions obvious).
