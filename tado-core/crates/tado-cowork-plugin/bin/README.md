# Plugin binaries

This directory holds the three Rust MCP servers the bundled
`tado-cowork-plugin` ships:

- `tado-mcp` — 16 `tado_*` tools (per-session A2A)
- `dome-mcp` — 18 `dome_*` tools (knowledge vault)
- `tado-use-bridge` — 41 `tado_use_*` tools (Tado control plane)

All three are built from the parent Cargo workspace
(`tado-core/crates/{tado-mcp, dome-mcp, ...}`) and from the Swift
package (`Sources/TadoUseBridge/`).

## How this directory gets populated

The Tado app's bundled installer (`CoworkPluginInstaller.install()`
in `Sources/Tado/Services/CoworkPluginInstaller.swift`) resolves
the plugin tree's path at runtime, expecting the bin directory to
already contain the three executables. The build system populates
this in two ways:

1. **Production (`make plugin`)**: copies the freshly-built release
   binaries from `tado-core/target/release/{tado-mcp, dome-mcp}`
   and the Swift product `.build/release/tado-use-bridge` into
   `tado-core/crates/tado-cowork-plugin/bin/`.

2. **Development (`make dev`)**: populates this directory with
   symlinks pointing at the live build outputs so a `cargo build`
   re-link picks up changes without re-copying.

If the bin/ directory is empty, `claude plugin install` will fail
with "command not found" the first time the Cowork session tries
to load any of the three MCP servers. Run `make plugin` or
`make dev` to populate.

## Why the plugin ships its own binaries vs. linking to user-installed ones

Two reasons:

1. **Version pinning.** The plugin's `mcpServers.dome.args` references
   `${USER_CONFIG.vaultPath}` + `${USER_CONFIG.domeToken}`, which is
   the contract the *bundled* `dome-mcp` understands. A user-installed
   `dome-mcp` from a different Tado version may have a different
   argv shape and would reject those args.

2. **Hermetic install.** `claude plugin install` is supposed to be
   one-click. Requiring the user to also have the matching Tado
   build installed at `~/.local/bin/` and on PATH would compound
   failure modes. The plugin shipping its own binaries means it
   either works fully or fails fully — no partial-success traps.

## .gitignore

This directory is gitignored — the binaries are build artifacts,
not source. The plugin's source-of-truth files (manifest, skill,
agent, this README) ARE checked in.
