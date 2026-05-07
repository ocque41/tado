---
name: cowork-tado-tools
description: |
  Teaches Cowork the Tado mental model and the full inventory of MCP
  tools the bundled `tado-cowork-plugin` exposes. Use whenever you
  (Cowork) are running inside a Tado-launched session — the launcher
  preamble starts with `[Tado run <id>]` — or whenever the user
  references a Tado canvas, project, todo, tile, eternal/dispatch run,
  Dome note, or Kanban board.
---

# Tado tool surface for Cowork

You are Claude Cowork running with the bundled `tado-cowork-plugin`
installed. That plugin gives you access to Tado's complete tool
inventory through three MCP servers:

| Server | Tools | What it controls |
|---|---|---|
| `tado` | 16 | Per-session A2A primitives (list/send/read across running tiles, broadcast, notifications, scoped config + memory, Pets sprite ops) |
| `dome` | 18 | Knowledge vault (hybrid + code search, notes, retrieval recipes, lifecycle: supersede/verify/decay, code watch, agent status) |
| `tado-use-bridge` | 41 | Drive Tado itself — navigation, modal/sheet control, todo + project + Eternal + Dispatch lifecycle, Kanban, settings, extensions |

**Total: 71 MCP tools** identical to what Claude Code sees on the
Tado canvas, available right here inside the Desktop app.

## The Tado mental model

- **Canvas** — a window of running terminal tiles, each one an
  agent (Claude Code, Codex, or Cowork).
- **Tiles** — a single agent session with its own PTY. Tiles live in
  a grid (e.g. `[1,1]`, `[2,1]`, `[1,2]`). They have a status:
  `pending`, `running`, `needsInput`, `awaitingResponse`,
  `completed`, `failed`.
- **Projects** — folders Tado tracks. Each project has working
  directory, todos, agents (in `.claude/agents/`), teams, an
  Eternal/Dispatch lifecycle, a Kanban board, and a Dome topic.
- **Todos** — units of work. Submitting a todo spawns a tile.
- **Eternal** — a long-running autonomous loop. The architect
  writes `crafted.md`; the worker iterates with a marker line.
  Two flavors: General (open-ended), Performance (perf-suite gate),
  Sprint (SprintSuccessScore gate).
- **Dispatch** — a multi-phase plan. The architect designs phases;
  per-phase agents handoff to the next. Tracks state in
  `.tado/dispatch/runs/<id>/`.
- **Dome** — the in-process knowledge vault: SQLite + chunked
  markdown notes + hybrid search (Qwen3 embeddings + FTS5) +
  retrieval recipes. Used as Tado's second brain.
- **Pets** — a floating-panel companion that mirrors agent
  activity onto the canvas.
- **Kanban** — per-project board view; columns are user-managed
  lanes, cards are todos.

## Output round-trip contract — IMPORTANT

When you've been launched from Tado (the prompt's preamble starts
with `[Tado run <id>]`), Tado opens you, attaches the project
folder, and waits for your result. The launcher's PTY closed
immediately — there's no streaming output channel. The way you
report back is by writing your final result markdown to the file
the preamble names:

    <projectRoot>/.tado/cowork/<runID>.md

Tado's `CoworkOutputPoller` watches that file (DispatchSource
file-system observer, debounced 500 ms, 30-min hard deadline).
The moment the file appears with non-empty content, Tado renders
it back into the originating canvas tile and transitions the tile
to `.completed`.

**What to put in the file**: a clear, scannable markdown report
that addresses the user's request, with section headings and
links to anything you produced (file paths, dome notes, kanban
cards, etc.). Keep it self-contained — the user reads this
inside a Tado tile, not inside the Desktop app.

**Always honor this contract** if the prompt starts with
`[Tado run <id>]`. If the user's prompt doesn't start with that
preamble, you're running in a vanilla Cowork session and don't
need to emit a result file.

## Tool reference — when to use which

### Knowledge & code search

- `dome_search { query, topic?, scope?, limit? }` — hybrid (vector + BM25)
  search across Tado's notes. Default for "what do we know about
  X" or "find the spec for Y."
- `dome_recipe_apply { intent_key }` — run a retrieval recipe
  (`architecture-review`, `completion-claim`, `team-handoff`).
  Returns a *governed answer* with citations. Use these instead
  of free-form `dome_search` when the user asks "what's the
  current architecture" / "is feature X done" / "how should the
  new agent inherit context."
- `dome_code_search { query, topic?, limit? }` — search across
  indexed code chunks (tree-sitter + Qwen3 embeddings).
- `dome_code_status` — list registered codebases + index health.
- `dome_read { id }` — full body of one note.
- `dome_graph_query { … }` — typed entity / edge queries.

### Knowledge writes

- `dome_note { topic, title, body, tags?, kind? }` — create a
  retro / decision / outcome / intent. Use when summarizing a
  finished investigation.
- `dome_supersede { old_id, new_id, reason? }` — chain an outdated
  note to its replacement. The old row stays visible for audit
  but rerank demotes it 0.3×.
- `dome_verify { node_id, verdict, agent_id?, reason? }` — flip
  a node's confidence to ≥0.9 (`confirmed`) or ≤0.4 (`disputed`).
- `dome_decay { node_id, reason? }` — soft-archive a node.

### Tile coordination (canvas A2A)

- `tado_list { project?, team? }` — list running tiles. Returns
  uuid, engine, grid, status, name. **Use this first** before
  trying to message another tile.
- `tado_read { target, tail?, raw? }` — read a tile's terminal
  output. `target` is uuid OR grid (`"1,1"`) OR name substring.
- `tado_send { target, message }` — send text to a running tile.
  Same target resolution.
- `tado_broadcast { message, project?, team? }` — send to every
  tile matching the filter.

When you delegate work to a Claude Code / Codex tile via
`tado_send`, identify yourself: include the run-id from your
preamble so the recipient can address you back via the result
file you're going to write. The tile will respond by writing
something *to its own log* — to read its response, poll
`tado_read <grid>` periodically.

### Tado control plane (drive the app itself)

- `tado_use_navigate { view }` — switch the Tado window to
  `details / canvas / projects / todos / extensions`.
- `tado_use_focus_tile { todo_id? OR grid? }` — focus a tile.
- `tado_use_app_state` — snapshot UI state (active project,
  focused tile, modal counts, session counts).
- `tado_use_list_tiles { project_id?, status? }` — list active
  tiles with full state.
- `tado_use_todo_create { project_id, text, spawn_tile? }` — make
  a new todo. With `spawn_tile=true` this immediately spawns the
  agent (default engine is whatever's set in Settings → Engine).
- `tado_use_todo_list / move / delete` — todo CRUD.
- `tado_use_project_list / create / resolve / delete` — project
  CRUD.
- `tado_use_eternal_start / accept / reject / list / status / stop / intervene`
  — Eternal run lifecycle. Don't poll faster than every ~10 s
  (architect needs thinking time).
- `tado_use_dispatch_start / accept / reject / list / status` —
  Dispatch lifecycle.
- `tado_use_kanban_columns / move_card` — Kanban board.
- `tado_use_settings_get / set` — read or set any GlobalSettings
  key by dotted path.
- `tado_use_extension_list / open` — Notifications, Dome,
  Cross-Run Browser, Pets.
- `tado_use_notify { title, body, severity }` — push a
  notification into Tado's banner overlay.
- `tado_use_tile_send / read / terminate` — full tile control,
  identical surface to the per-session `tado_*` tools but routed
  through the Tado app's control socket so it works even when
  you don't have the tile's session id handy.
- `tado_use_events_query` — last 500 events from Tado's event
  ring buffer (terminal completed, eternal phase change, ipc
  messages, etc.).

### Memory & config

- `tado_memory_read / append / search { scope }` — markdown
  memory files Tado keeps under `~/Library/Application Support/Tado/memory/`.
  Scopes: `user` (~/Library/.../memory/user.md), `project`
  (`<project>/.tado/memory/project.md`), `global` (Tado-wide).
- `tado_config_get / set / list { scope }` — five-scope config
  hierarchy: runtime > project-local > project-shared > user-global > built-in default.

### Agent operations feed

- `dome_agent_status` — the live feed of every Claude Code session
  on the user's machine. Returns `{captured_at, model, ctx_pct,
  cost, …}` for each session. Use to figure out which tiles are
  hot vs idle before sending work.

## Collaboration patterns

**Pattern: Cowork as planner, canvas tiles as executors.**

You sit in the Desktop app and read Dome (`dome_search`,
`dome_recipe_apply`), reason about the project, and delegate
executable work to running canvas tiles via `tado_send`. The
tiles do the actual file edits + builds + tests; you summarize
their outputs back into your result file.

Example:

1. User asks Cowork: "audit the auth module and produce a
   refactor plan."
2. You: `dome_recipe_apply { intent_key: "architecture-review" }`
   to grab the current authority on auth.
3. You: `tado_list { project: <name> }` to see what canvas tiles
   are running.
4. You: `tado_use_todo_create { project_id, text: "Show me every
   call site of OldAuthMiddleware", spawn_tile: true }` — spawns
   a fresh Claude Code tile to do the grep work.
5. You: poll `tado_use_app_state` until the new tile's status is
   `.completed`, then `tado_use_tile_read` to ingest its output.
6. You: synthesize the architecture review + the call-site dump
   into a refactor plan, write to
   `<projectRoot>/.tado/cowork/<runID>.md`.
7. Tado's poller fires → result lands in the originating tile.

**Pattern: Cowork mirrors a long-running Eternal.**

If the user has an Eternal run going and asks for high-level
context, use `tado_use_eternal_status` to read crafted.md +
metrics.jsonl, then summarize. Don't `tado_use_eternal_intervene`
unless the user explicitly asks — that mutates the worker's
inbox.

**Pattern: Knowledge writeback from Cowork.**

After a long Cowork session that produced novel findings, end
with `dome_note { topic: project-<shortid>, title: <descriptive>,
body: <markdown>, kind: "retro" }` so the next Tado tile has
your work to read.

## Hard rules

1. **Respect the output round-trip.** If the prompt starts with
   `[Tado run <id>]`, you must end by writing markdown to the
   stated `<projectRoot>/.tado/cowork/<runID>.md`. Tado's tile
   is waiting for that file.
2. **Don't `tado_use_settings_set` without explicit user consent.**
   It mutates user-owned config files.
3. **Don't poll Eternal/Dispatch status faster than 10 s.** The
   architect tile needs thinking time and you'd burn tokens.
4. **Use recipes before free-form search.** `dome_recipe_apply`
   gives you a governed answer with citations — that's the
   authority surface. Free-form `dome_search` is for cases the
   recipes don't cover.
5. **Never read or modify files outside the attached folder.**
   Cowork's per-folder permission is the user's only firewall;
   honor it.
