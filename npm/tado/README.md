# tado

CLI-first Tado runtime and Agent OS terminal UI.

```bash
npx tado
# or
npm install -g tado
tado
```

Run `tado` to open the Agent OS TUI. It starts a profile-owned `tadod` runtime
daemon when needed, so the macOS desktop app does not need to be running.

`tadod` is also installed for explicit daemon control and diagnostics. Normal
users should start from `tado`; the helper commands (`tado-list`, `tado-read`,
`tado-send`, `tado-events`, `tado-deploy`, and the workflow aliases) route to
the active CLI runtime profile.

## TUI controls

The Use page is the command/control reference. Other pages are data-first views.

- `Tab` / `Shift-Tab`: move between Agent OS pages.
- `Shift+1`-`Shift+7`: jump directly to Work, Board, Mux, Events, Use, Projects, Settings.
- Board mode renders a side-by-side Kanban board with one lane per column.
- `PageUp` / `PageDown` or `Ctrl-U` / `Ctrl-D`: scroll the current page.
- `End`: follow the selected agent transcript.
- `/`: open command autocomplete, including `/project` and `/projects`.
- `Enter`: complete the highlighted command first, then run/send once arguments are present.
- Plain text + `Enter` on Work/Mux: send to the selected live PTY.
- Plain text + `Enter` on Projects: spawn the default agent in the selected project.
- `Shift+X`: kill and delete the selected runtime session.
- Settings uses `Up` / `Down`, `Left` / `Right`, and `Space` to change choices instead of raw JSON.
- Events defaults to a human-readable timeline; Settings can switch it back to JSON.

## Projects

Profiles can register and select projects without the desktop app.

```bash
tado project add ~/Code/my-app --name my-app
tado project add ~/Code/new-app --name new-app --create
tado project list
tado project use my-app
tado project status
```

In the TUI, use the Projects page or prompt commands:

```text
/project add <existing-path> [name]
/project create <new-path> [name]
/project use <name|path|id>
/project list
```

On the Projects page, `Up` / `Down` selects a project and `Space` makes it
active. You do not need to type `/project use ...` before every agent prompt:
typing a normal prompt on Projects spawns the configured default agent in the
selected project and passes that project root into the runtime.

Project paths typed without a leading slash are user-home relative, so
`documents/gg`, `downloads/demo`, and `my-app` resolve under `~` instead of
the current shell directory. Use `./local-app` or `../local-app` when you
explicitly want a path relative to the current directory.

New `/spawn`, `/claude`, `/codex`, `/cowork`, and `/bootstrap` commands use
the active project as their working directory and `TADO_PROJECT_ROOT`.

## Publishing

Publish only with an npm token supplied through the environment, never from a
checked-in config file:

```bash
cd npm/tado
npm pack --dry-run
tmp_config="$(mktemp)"
printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > "$tmp_config"
NPM_CONFIG_USERCONFIG="$tmp_config" npm publish --access public
rm -f "$tmp_config"
```

Set `NPM_TOKEN` or `NODE_AUTH_TOKEN` in the shell used for publishing.
