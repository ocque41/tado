Prebuilt `tado` runtime binaries are copied here before packaging:

- `darwin-arm64/tado`
- `darwin-arm64/tadod`
- `darwin-arm64/tado-tui`
- `darwin-arm64/tado-list`
- `darwin-arm64/tado-read`
- `darwin-arm64/tado-send`
- `darwin-arm64/tado-events`
- `darwin-arm64/tado-deploy`
- `darwin-arm64/tado-bootstrap`
- `darwin-arm64/tado-kanban`
- `darwin-arm64/tado-eternal`
- `darwin-arm64/tado-dispatch`
- `darwin-arm64/tado-mcp`
- `darwin-x64/tado`
- `darwin-x64/tadod`
- `darwin-x64/tado-tui`
- `darwin-x64/tado-list`
- `darwin-x64/tado-read`
- `darwin-x64/tado-send`
- `darwin-x64/tado-events`
- `darwin-x64/tado-deploy`
- `darwin-x64/tado-bootstrap`
- `darwin-x64/tado-kanban`
- `darwin-x64/tado-eternal`
- `darwin-x64/tado-dispatch`
- `darwin-x64/tado-mcp`

The npm wrapper invokes the binary matching the installed command name. `tado`
is the public TUI entrypoint and launches the internal `tado-tui` prebuilt.
`tadod` is the public daemon entrypoint. Aliases fail loudly if their matching
prebuilt is missing.
