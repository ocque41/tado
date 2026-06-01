# @tt0/tado Changelog

## 0.3.0

- Renamed the public npm package to `@tt0/tado`.
- Ships the terminal Agent OS as a Codex-only public provider.
- Keeps `shell` and `raw` as utility session kinds.
- Rejects legacy `claude` and `cowork` requests in runtime-backed terminal flows.
- Uses `.codex/agents/` for terminal Agent OS agent definitions.
- Adds `tado-projects` and `tado-system` to the npm binary surface.
- Removes `tado-cowork` from the release package.
- Keeps Rust crates internal and distributes prebuilt binaries through npm.
