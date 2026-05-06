.PHONY: dev debug release build clean core core-clean core-test all-test bench core-bench sync-header mcp bridge perf-suite perf-bench perf-detect perf-test

# Daily development: release-optimized Rust core + header sync + Swift app.
# Launching the app this way boots Tado AND (via DomeExtension.onAppLaunch)
# the in-process Dome second-brain daemon in a single process.
dev: sync-header
	swift run -c release

debug: sync-header
	swift run -c debug

release: build

build: sync-header
	swift build -c release

clean:
	swift package clean
	rm -rf .build

# Rust core (Phase 1+). Produces tado-core/target/release/libtado_core.a,
# tado-core/target/release/dome-mcp, tado-dome, and tado-core/include/tado_core.h.
# `dome-mcp` is Dome's stdio MCP bridge shipped alongside the app so
# Claude Code agents running inside Tado terminals can reach bt-core
# over the Unix socket the app opened at launch.
core:
	cd tado-core && cargo build --release

# Keep Sources/CTadoCore/include/tado_core.h in lock-step with the
# header cbindgen writes into tado-core/include/. Swift's CTadoCore
# target reads from the first path; cbindgen writes to the second. A
# plain copy after `core` avoids the "symbol exists in libtado_core.a
# but Swift can't see it" trap foundation-v2 hit once when adding
# Dome FFI entries.
sync-header: core
	cp tado-core/include/tado_core.h Sources/CTadoCore/include/tado_core.h

# Build just the MCP bridges. Useful when iterating on dome-mcp or
# tado-mcp's tool surface without rebuilding the whole Swift app.
# Also rebuilds tado-use-bridge, the Swift stdio MCP server that
# proxies the six SwiftUI control tools through the running app's
# control socket.
mcp: bridge
	cd tado-core && cargo build --release -p dome-mcp -p tado-mcp -p tado-dome

# Build the Tado Use stdio MCP bridge (Swift exec target). Lives
# next to dome-mcp / tado-mcp inside Tado.app/Contents/MacOS/ once
# the app is bundled; in dev runs out of .build/release/.
bridge:
	swift build -c release --product tado-use-bridge

core-test:
	cd tado-core && cargo test --release

core-clean:
	cd tado-core && cargo clean

all-test: core core-test
	swift test

# Rust microbenchmarks via criterion.
core-bench:
	cd tado-core && cargo bench --bench grid_bench

# Full bench suite: Rust microbenchmarks + Swift renderer .measure blocks.
# Results get written to bench/BENCH.md manually after inspection.
bench: core-bench
	swift test --filter RendererBenchTests

# Build the perf-suite binary used by the Eternal Performance step's
# perf-gate.sh hook. Release-mode optimization matters here because
# the gate runs every Eternal worker iteration in perf mode.
perf-suite:
	cd tado-core && cargo build --release -p perf-suite

# Run perf-suite's own self-bench (Criterion). Validates the suite's
# scoring + slope-fit + baseline-update hot paths complete in a few
# microseconds — required so the gate doesn't itself become a perf
# bottleneck.
perf-bench:
	cd tado-core && cargo bench -p perf-suite

# Smoke-test perf-suite on the project Tado lives in. Useful for
# confirming the binary is wired correctly after a build.
perf-detect: perf-suite
	cd tado-core && cargo run --release -p perf-suite -- detect --project-root $(PWD)

# Run perf-suite's full test matrix (unit + integration + fixtures).
perf-test:
	cd tado-core && cargo test -p perf-suite
