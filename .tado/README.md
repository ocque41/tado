# .tado/

This directory holds per-project state for **Tado**, a macOS terminal
multiplexer for AI coding agents (https://tado.app).

## What's in here

| File / folder       | Committed? | Purpose                                                            |
|---------------------|------------|--------------------------------------------------------------------|
| `config.json`       | yes        | Project-shared settings — engine, eternal mode, sprint prompts.    |
| `local.json`        | no         | Per-machine overrides. Gitignored by default.                      |
| `memory/project.md` | yes        | Long-lived context agents auto-inject on spawn.                    |
| `memory/notes/`     | yes        | Timestamped agent notes. Searchable via `tado-memory search`.      |
| `eternal/runs/`     | no         | Per-run state for Eternal (long-running agent loops).              |
| `dispatch/runs/`    | no         | Per-run state for Dispatch (multi-phase architect plans).          |
| `hooks/`            | yes        | Bash hooks shared with the team.                                   |
| `.gitignore`        | yes        | Auto-maintained by Tado based on `config.json → commitPolicy`.     |

## Changing what's committed

`config.json` has a top-level `"commitPolicy"` field:

- `"shared"` (default) — `config.json` is tracked; `local.json` is gitignored.
- `"local-only"` — both files gitignored; nothing Tado-specific leaks to git.
- `"none"` — Tado stops managing `.gitignore`; you maintain it yourself.

Set via the Settings UI, or from the terminal:

```bash
tado-config set project commitPolicy '"local-only"'
```

## Safe to delete?

Yes — Tado rebuilds it from SwiftData state on next launch. But teammates
will lose anything you had committed (prompts, memory, hooks).
