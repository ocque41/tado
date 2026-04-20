# Tado Persistence + Notifications

Reference for the two subsystems that shipped in packets 1–10: how
state is stored (settings, state, memory) and how events surface to
the user (in-app, macOS system, Dock, sound, log).

Written to be read cold — no assumed context beyond "I'm using Tado
and want to understand what's on disk."

---

## 1. Where things live

```
~/Library/Application Support/Tado/
├── settings/
│   └── global.json                       # user-global settings (scope 4)
├── memory/
│   ├── user.md                           # user-level long-lived context
│   └── user.json                         # user-level cached facts (unused in packet 7)
├── events/
│   ├── current.ndjson                    # append-only event log
│   └── archive/events-YYYY-MM-DD.ndjson  # rotated daily
├── backups/
│   └── tado-backup-YYYY-MM-DD-HHmmss*.tar.gz
├── cache/                                # SwiftData cache (rebuildable)
├── logs/                                 # reserved (future os.Logger exports)
└── version                               # last-applied migration id

<project>/.tado/
├── config.json                           # project-shared settings (scope 3)
├── local.json                            # project-local overrides (scope 2)
├── memory/project.md                     # project long-lived context
├── memory/notes/<ISO>-<slug>.md          # timestamped notes
├── eternal/runs/<uuid>/                  # per Eternal run
├── dispatch/runs/<uuid>/                 # per Dispatch run
├── hooks/                                # bash hooks
├── .gitignore                            # auto-maintained
└── README.md                             # teammate-facing primer
```

---

## 2. Scope hierarchy

Settings merge bottom-up; the highest scope that *defines a value* wins:

| # | Scope            | Lifetime                        | Where                                                    |
|---|------------------|---------------------------------|----------------------------------------------------------|
| 1 | Runtime          | one invocation                  | CLI flag / env var (`TADO_*`)                            |
| 2 | Project-local    | this project, this machine      | `<project>/.tado/local.json` (gitignored)                |
| 3 | Project-shared   | this project, everyone          | `<project>/.tado/config.json` (committed by default)     |
| 4 | User-global      | this user, every project        | `~/Library/Application Support/Tado/settings/global.json`|
| 5 | Built-in default | shipped with the binary         | `GlobalSettings.swift` struct literals                   |

Example: `engine.default` in the built-in default is `"claude"`. Your
user-global sets it to `"codex"`. Project-shared sets it back to
`"claude"`. You invoke with `--engine codex`. Effective value: `codex`.

---

## 3. Canonical store: JSON on disk

Every JSON file begins with three reserved fields:

```json
{
  "schemaVersion": 1,
  "writer": "tado-app",
  "updatedAt": "2026-04-20T14:32:01Z",
  ...
}
```

- **`schemaVersion`** — integer. Migrations branch on this. Never remove fields between bumps.
- **`writer`** — free-text tag for debugging ("tado-app", "tado-config-cli", "tado-mcp", "migration-002").
- **`updatedAt`** — ISO 8601 UTC. Enables last-writer-wins arbitration.

### Atomic writes + advisory locks

All writes go through `AtomicStore` (Swift) or the bash `flock + tmp + mv` pattern (CLI):

```
1. acquire exclusive flock on <path>.lock
2. write <path>.tmp-<pid>
3. fsync, then rename <path>.tmp-<pid> → <path>  (POSIX-atomic)
4. release lock
```

Readers never see a torn file because the rename is atomic.

### SwiftData is a cache

SwiftData's `AppSettings` and `Project` rows are **caches** fed from
`global.json` and `<project>/.tado/config.json` by `AppSettingsSync`
and `ProjectSettingsSync`. If `cache/tado.sqlite` corrupts:

```bash
rm -rf ~/Library/Application\ Support/Tado/cache
# relaunch Tado — cache rebuilds from JSON on first query
```

### External edits flow back

Every canonical file is watched by `FileWatcher`. If you `vim
global.json` or `tado-config set ...` from a terminal, the Swift app:
1. Notices the fd change (200ms debounce).
2. Re-reads the JSON.
3. Applies the diff to the SwiftData cache row.
4. SwiftUI `@Query` observers redraw automatically.

---

## 4. Per-project commit policy

`config.json` carries a top-level `"commitPolicy"` field that governs
`.tado/.gitignore`:

| Policy         | `config.json`        | `local.json`   | Behavior                                               |
|----------------|----------------------|----------------|--------------------------------------------------------|
| `shared` (def) | tracked by git       | gitignored     | Team inherits engine / eternal / memory / hooks.       |
| `local-only`   | gitignored           | gitignored     | Nothing Tado-specific leaks to git.                    |
| `none`         | up to user           | up to user     | Tado stops managing `.gitignore`; hand-maintain it.    |

Flip policy anywhere:

- **Settings UI** → Notifications / Storage / etc. (upcoming packet: Project tab).
- **CLI**: `tado-config set project commitPolicy '"local-only"'`
- **MCP**: `tado_config_set({scope: "project", key: "commitPolicy", value: "local-only"})`
- **Text editor**: edit `config.json` directly.

---

## 5. Migrations

`~/Library/Application Support/Tado/version` stores the last-applied
migration id (integer). On app launch, `MigrationRunner` applies any
migration whose id > stored, in ascending order, bumping the marker
after each success.

Before applying the first pending migration, `BackupManager.createBackup`
tars everything in `~/Library/Application Support/Tado/` (excluding
`backups/`, `cache/`, `logs/`) into `backups/tado-backup-<ts>-pre-migration.tar.gz`.
If a migration corrupts state, untar the snapshot back into place.

Current migrations:

| Id | Name                                         |
|----|----------------------------------------------|
| 1  | Create `global.json` from SwiftData AppSettings |
| 2  | Create per-project `config.json` + README + `.gitignore` |

Adding a new migration: drop a file in `Sources/Tado/Persistence/Migrations/`,
append to `MigrationRunner.all`, bump nothing else. Migrations **must**
be idempotent — a partial run that aborts mid-way will be retried from
the start on the next launch.

---

## 6. Event system

### Event flow (plan §5)

Every meaningful state transition publishes a typed `TadoEvent`:

1. **Producer** calls `EventBus.shared.publish(.terminalCompleted(...))`.
2. `EventPersister` appends one NDJSON line to `events/current.ndjson` (fsynced).
3. Registered **deliverers** fan out:
   - `InAppBannerOverlay` — top-right transient pill, 5s auto-dismiss, stack of 3.
   - `SoundPlayer` — plays a severity-mapped sound.
   - `DockBadgeUpdater` — sets `NSApp.dockTile.badgeLabel`.
   - `SystemNotifier` — `UNUserNotificationCenter` banner when app isn't frontmost.
4. The event lands in `EventBus.recent` (bounded in-memory ring, 500 latest).

### Routing + mute precedence

For each event type, three gates decide per-channel delivery:

1. `notifications.channels.<channel>` — global mute switch per channel.
2. `notifications.quietHours.{enabled,from,to}` — time window that mutes `sound` + `system`.
3. `notifications.eventRouting[<type>]` — list of channel names allowed for that type.

For `terminal.bell`, `ui.bellMode` is the authoritative decision
(matches Terminal.app conventions): `off` / `audible` / `visual` / `both`.

### Event taxonomy

```
terminal.spawned         terminal.spawnFailed
terminal.needsInput      terminal.completed
terminal.failed          terminal.bell
ipc.messageReceived      ipc.messageDelivered
eternal.runStarted       eternal.phaseCompleted
eternal.runCompleted     eternal.runStopped
eternal.workerWedged
dispatch.planReady       dispatch.phaseStarted
dispatch.phaseCompleted  dispatch.runCompleted
config.externallyChanged
system.appLaunched       system.appQuitting
system.migrationRan
user.broadcast
```

Each event carries `id`, `ts`, `type`, `severity` (info / success /
warning / error), `source` (kind + optional session/project/run ids),
`title`, `body`, optional `actions`.

### Durable before visible

Events always hit disk (`events/current.ndjson`) before any deliverer
runs. If you miss a banner because the app was quit, the event is
still in history. The notifications bell (sidebar, top-right) opens
`NotificationsView` which reads `EventBus.recent`; older entries are
reachable via `events/archive/*.ndjson`.

---

## 7. CLI surface

All three write through the same atomic-store discipline as the Swift
app (flock + tmp + mv). Installed to `~/.local/bin/` alongside existing
`tado-list` / `-send` / `-read` / `-deploy`.

### tado-config

```
tado-config get    <scope> <dot.key>          # read one value
tado-config set    <scope> <dot.key> <value>  # write (JSON-parsed if possible)
tado-config list   [scope]                    # dump file
tado-config path   [scope]                    # print absolute path
tado-config export <tarball>                  # full backup to .tar.gz
tado-config import <tarball>                  # restore from .tar.gz
```

Scopes: `global`, `project` (or `project-shared`), `local` (or
`project-local`).

### tado-notify

```
tado-notify send "<title>" [--body "<body>"] [--severity info|success|warning|error]
tado-notify tail [N]                          # last N events
```

Writes directly to `events/current.ndjson`. Works whether or not
Tado.app is running — events land in the durable log either way.

### tado-memory

```
tado-memory read   [scope]                    # cat the file
tado-memory path   [scope]
tado-memory note   "<text>" [--scope project|user] [--tag a,b]
tado-memory search <query> [--scope project|user|all]
```

Agents running inside a Tado tile can call `tado-memory note ...`
directly from their shell — no MCP required — to persist durable
facts for future spawns.

---

## 8. MCP surface

Eight new tools on the `tado-mcp` Node server (registered alongside
the existing `tado_list` / `tado_read` / `tado_send` / `tado_broadcast`):

| Tool                    | Purpose                                      |
|-------------------------|----------------------------------------------|
| `tado_config_get`       | Read one dotted key.                         |
| `tado_config_set`       | Atomically write one dotted key.             |
| `tado_config_list`      | Dump the whole settings file for a scope.    |
| `tado_memory_read`      | Return memory markdown for user/project.     |
| `tado_memory_append`    | Append a timestamped note.                   |
| `tado_memory_search`    | Substring search across memory + notes.      |
| `tado_notify`           | Publish a user-visible event.                |
| `tado_events_query`     | Read recent events, filtered by type/severity/since. |

All tools use the same paths + encoding as the Swift app. An agent
running in a Tado tile can call `tado_memory_append` from its MCP
session and the next spawn (Claude or Codex) picks up the note.

---

## 9. Export + import

Two surfaces, same outcome — tarball round-trip of the entire
`~/Library/Application Support/Tado/` tree (minus caches + backups):

- **Settings UI** → Storage section → `Export backup…` / `Import backup…`
- **CLI**:
  ```bash
  tado-config export /tmp/tado-backup.tar.gz
  tado-config import /tmp/tado-backup.tar.gz   # relaunch to pick up
  ```

After import, relaunch Tado so SwiftData rebuilds from the restored
JSON and watchers re-attach to the new tree.

---

## 10. Common operations

### I want my teammate to inherit my Eternal sprint prompts

Default policy (`shared`) already commits `config.json`, which carries
`eternal.sprintEval` and `eternal.sprintImprove`. Just commit `.tado/`:

```bash
git add .tado/config.json .tado/memory/project.md .tado/hooks
git commit -m "seed tado config"
```

### I don't want any Tado state in my git repo

```bash
tado-config set project commitPolicy '"local-only"'
# .tado/.gitignore now ignores config.json too.
```

### I want Dock badges but not macOS banners

Settings → Notifications → turn off **macOS system notifications**.
Or:

```bash
tado-config set global notifications.channels.system false
```

### I want to silence everything between 10pm and 8am

```bash
tado-config set global notifications.quietHours.enabled true
tado-config set global notifications.quietHours.from '"22:00"'
tado-config set global notifications.quietHours.to '"08:00"'
```

In-app banners + Dock badges still fire during quiet hours (they're
non-intrusive); sound + system banners stay silent.

### An agent wants to remember "user prefers pnpm over npm"

From inside a tile's terminal:

```bash
tado-memory note "prefers pnpm over npm — user corrected during setup" --tag tooling
```

Future spawns automatically inject `memory/project.md` into their
prompt prefix (max `memory.injectBudget` tokens, default 2000).

### The event log is getting long

`current.ndjson` auto-rotates at UTC midnight into
`archive/events-YYYY-MM-DD.ndjson`. To clear manually:

```bash
rm ~/Library/Application\ Support/Tado/events/current.ndjson
# relaunch — a fresh one is created on the first publish.
```

### SwiftData cache looks weird

```bash
rm -rf ~/Library/Application\ Support/Tado/cache
# relaunch — cache rebuilds from JSON.
```

---

## 11. What's intentionally NOT here

From the plan's §9 (non-goals), honored as shipped:

- No cloud sync — everything is local-first.
- No remote notifications (push, email, Slack).
- No dispatch watchdog / auto-retry.
- No user-authored notification rules DSL.
- No SwiftData ongoing migration ceremony — cache is disposable.

Deferred from packet 10 for safety, pickable up in a future touch-up
packet:

- Formal `tado://` URL scheme registration via Info.plist (requires
  app-bundle refactor). `SystemNotifier`'s click-handler already
  activates the app + marks the event read; deep-linking to a specific
  tile/run awaits the scheme.
- Unix-domain socket `bus.sock` for live CLI → app push (today the
  CLI writes to the NDJSON log directly and the app picks up on
  relaunch — missed events are still in history).
- Retiring vestigial `AppSettings` SwiftData columns (`useMetalRenderer`,
  the one-shot migration flags). They're ignored today; removal
  requires a SwiftData migration that's not worth the regression
  risk right now.
