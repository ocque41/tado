# Prebuilt Binaries

`@tt0/tado` ships macOS prebuilt Rust binaries under:

- `darwin-arm64/`
- `darwin-x64/`

Each target directory must contain executable `755` files for:

- `tado`
- `tadod`
- `tado-list`
- `tado-read`
- `tado-send`
- `tado-events`
- `tado-deploy`
- `tado-bootstrap`
- `tado-kanban`
- `tado-eternal`
- `tado-dispatch`
- `tado-mcp`
- `tado-projects`
- `tado-system`

`tado-cowork` is intentionally not shipped. The terminal Agent OS release is
Codex-only; `shell` and `raw` are utility session kinds, not AI providers.

Build from the workspace root:

```bash
cd tado-core
cargo build --release -p tado-runtime --bin tadod -p tado-cli --bins -p tado-mcp --bin tado-mcp
cargo build --release --target x86_64-apple-darwin -p tado-runtime --bin tadod -p tado-cli --bins -p tado-mcp --bin tado-mcp
```

Then copy the binaries into the matching target directories and run:

```bash
chmod 755 npm/tado/prebuilt/darwin-*/*
```
