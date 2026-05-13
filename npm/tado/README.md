# @cumulus_cloud/tado

Terminal launcher for Tado's agent work view.

```bash
npx @cumulus_cloud/tado
# or
npm install -g @cumulus_cloud/tado
tado
```

The command expects the Tado macOS app to already be running. If Tado is not
running, the TUI shows a launch-Tado message instead of failing silently.
`tado-tui` is kept as a compatibility alias for the same command.

## Publishing

Publish only with an npm token supplied through the environment, never from a
checked-in config file:

```bash
cd npm/tado
npm pack --dry-run
tmp_config="$(mktemp)"
printf '//registry.npmjs.org/:_authToken=${NPM_TOKEN}\n' > "$tmp_config"
NPM_CONFIG_USERCONFIG="$tmp_config" npm publish --access public
rm -f "$tmp_config"
```

Set `NPM_TOKEN` or `NODE_AUTH_TOKEN` in the shell used for publishing.
