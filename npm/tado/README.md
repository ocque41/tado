# @tt0/tado

Codex-only terminal Agent OS for macOS.

```bash
npx @tt0/tado
# or
npm install -g @tt0/tado
tado
```

`tado` opens the Agent OS TUI and starts a profile-owned `tadod` runtime
daemon when needed. The desktop app is not required.

## Requirements

- macOS on Apple Silicon or Intel.
- Node.js 18 or newer for the npm launcher.
- The Codex CLI installed and authenticated in your shell.

Tado does not store Codex credentials. The runtime profile stores only
non-secret provider preferences such as model, reasoning effort, permission
mode, alternate-screen behavior, and the account label `default`, which uses
your existing Codex CLI auth.

## Commands

The npm package installs these binaries:

- `tado` - public TUI entrypoint.
- `tadod` - profile daemon.
- `tado-list`, `tado-read`, `tado-send`, `tado-events` - runtime A2A helpers.
- `tado-deploy` - spawn a new runtime session.
- `tado-bootstrap`, `tado-kanban`, `tado-eternal`, `tado-dispatch`.
- `tado-mcp` - Rust MCP bridge.
- `tado-projects`, `tado-system`.

`codex` is the only public AI provider. `shell` and `raw` remain utility
session kinds for terminal work. Legacy `claude` and `cowork` requests are
rejected with clear errors.

## TUI Controls

- `Tab` / `Shift-Tab`: move between Agent OS pages.
- `Shift+1`-`Shift+7`: jump to Work, Board, Mux, Events, Use, Projects, Settings.
- `/`: open command autocomplete.
- `/codex <prompt>`: spawn a Codex session.
- `/spawn <command>`: spawn a shell PTY utility session.
- Plain text + `Enter` on Projects: spawn the default Codex agent in that project.
- `Shift+X`: kill and delete the selected runtime session.
- Settings uses arrows and `Space` instead of raw JSON.

Agent definitions are read from `.codex/agents/`.

## Package Notes

This package ships prebuilt Rust binaries for `darwin-arm64` and `darwin-x64`.
The Rust crates are internal to this release and are not published to crates.io.

To verify a generated tarball:

```bash
cd npm/tado
npm pack --dry-run --json
npm pack
prefix="$(mktemp -d)"
npm install --prefix "$prefix" ./tt0-tado-0.3.0.tgz
"$prefix/bin/tado" --help
"$prefix/bin/tadod" --help
```

Publishing should use a temporary npm config or environment token only. Do not
commit tokens:

```bash
tmp_config="$(mktemp)"
printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > "$tmp_config"
NPM_CONFIG_USERCONFIG="$tmp_config" npm publish --access public
rm -f "$tmp_config"
```
