# Sprint 1 postmortem — confkit + per-phase model/effort

## What got built

- Tado Dispatch feature gained **per-phase model/effort support** (ladder A).
  - `TerminalSession` has new `modelFlagsOverride` / `effortFlagsOverride` fields.
  - `AgentDiscoveryService.phaseOverride(agentName:projectRoot:)` parses YAML
    frontmatter `model:` + `effort:` from an agent file and maps them to
    `--model <id>` + `--effort <level>` CLI flags. Short names → full model
    IDs (`haiku` → `claude-haiku-4-5`, `sonnet` → `claude-sonnet-4-6`,
    `opus` → `claude-opus-4-7`).
  - `CanvasView` prefers the per-session override over
    `AppSettings.claudeModel`/`claudeEffort` when mounting tiles.
  - `ContentView.handleSpawnRequest` (tado-deploy path) and
    `DispatchPlanService.startPhaseOne` set overrides from the resolved
    agent file on spawn.
  - Dispatch Architect prompt (STEP 2 + STEP 4) now routes each phase to
    `haiku`/`high` by default, `haiku`/`max` for dense phases, and
    `opus`/`max` only for genuine design-heavy phases. Passes `model` +
    `effort` to `/tado-dispatch-agent-creator`.
  - `tado-dispatch-agent-creator` SKILL.md now requires + emits both
    `model:` and `effort:` frontmatter fields, documents the CLI-flag
    mapping, and validates them in self-check.

- Trial project **confkit** at `~/Documents/eternal-trials/sprint-1-confkit/`:
  - 6-phase dispatch plan (`.tado/dispatch/plan.json` + phases + retros).
  - 6 agent files with `model:` + `effort:` frontmatter — one Opus/max
    (phase 1, AST design), five Haiku/max (volume work).
  - Full Node 20+/ESM impl: shared AST, 5 parsers + 5 emitters, detect,
    CLI, index. 41 round-trip tests + 12 shell smoke conversions, all
    green. README lists every flag + format + worked example.

## What broke

- The running Tado instance is the binary from before the improvement
  commit. To actually exercise the new per-phase code, the user must
  restart Tado — the code-level wiring is verified by inspection + build
  but can only be end-to-end validated after a relaunch.
- The trial pivoted from Bun/TypeScript (as authored in dispatch.md) to
  Node/ESM mid-sprint because Bun isn't installed on this machine.
  dispatch.md still mentions Bun in places; phase JSON + README now
  describe Node. Minor plan-coverage friction.
- No *real* architect dispatch was attempted this sprint — the plan +
  phase files + adapters were authored by the Eternal worker acting as
  a stand-in. Sprint 2 should attempt a genuine end-to-end dispatch
  once the user restarts Tado so the new architect prompt is active.

## Next improvement

Stay on ladder A / B until real dispatches stabilise. Candidate next
sprint: **B. Plan validity / coverage** — architect STEP 5.5 that
re-reads its own plan.json against dispatch.md acceptance criteria and
rewrites missing coverage before STOP. This addresses the bun→node
drift seen this sprint: the architect should catch that phase
deliverables don't match what dispatch.md promised.
