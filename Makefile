.PHONY: dev debug release build clean core core-clean core-test all-test bench core-bench sync-header mcp

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
mcp:
	cd tado-core && cargo build --release -p dome-mcp -p tado-mcp -p tado-dome

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
