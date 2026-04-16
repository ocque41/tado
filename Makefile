.PHONY: dev debug release build clean core core-clean

# Daily development: release-optimized build (5-10× faster than default `swift run`)
dev:
	swift run -c release

# Debug build for stepping through with LLDB
debug:
	swift run -c debug

release: build

build:
	swift build -c release

clean:
	swift package clean
	rm -rf .build

# Rust core (Phase 1+)
core:
	cd tado-core && cargo build --release

core-clean:
	cd tado-core && cargo clean
