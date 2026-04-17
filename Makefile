.PHONY: dev debug release build clean core core-clean core-test all-test

# Daily development: release-optimized Rust core + Swift app.
dev: core
	swift run -c release

debug: core
	swift run -c debug

release: build

build: core
	swift build -c release

clean:
	swift package clean
	rm -rf .build

# Rust core (Phase 1+). Produces tado-core/target/release/libtado_core.a
# and tado-core/include/tado_core.h which CTadoCore imports.
core:
	cd tado-core && cargo build --release

core-test:
	cd tado-core && cargo test --release

core-clean:
	cd tado-core && cargo clean

all-test: core core-test
	swift test
