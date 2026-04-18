# Sprint 2 postmortem — fixgen-2 + architect STEP 5.5 self-check

## What got built

- **Tado Dispatch — Rung 2 improvement.** Added `STEP 5.5 — SELF-CHECK
  PLAN COVERAGE` to `dispatchArchitectPrompt` in
  `Sources/Tado/Services/ProcessSpawner.swift`, between STEP 5 (write plan
  files) and STEP 6 (author phase prompts). The new step has five sub-
  parts:
  1. Enumerate dispatch.md's acceptance criteria as a numbered list.
  2. Mark each criterion COVERED / PARTIAL / MISSING against the just-
     written phase JSONs.
  3. Stack-drift check — every phase prompt must name the chosen runtime,
     test harness, module format, and package manager verbatim. This
     directly targets the bun→node drift postmortem'd in sprint 1.
  4. Rewrite offending phase prompts in-place (don't append notes). Prefer
     merging over adding phases; if a phase is added, update plan.json's
     `totalPhases` and every `nextPhaseFile` pointer.
  5. Print a coverage/drift audit summary or "audit clean" and proceed.

  `swift build` stays green (verified twice — once after the edit, once
  after the trial project shipped).

- **Trial project: `fixgen-2`** at `~/Documents/fixgen-2/` (top-level,
  visible in Finder per the hard rule):
  - **~30 files**, ~900 LOC of production + ~430 LOC of tests.
  - Zero npm dependencies. Node 20+ / ESM / `node --test`.
  - 6-phase dispatch plan (`plan.json` + 6 phase JSONs + 6 retros).
  - Core layout: `src/rng.mjs` (Mulberry32 + FNV-1a-32), `src/schema.mjs`
    (loadSchema + path-prefixed validator), `src/types/` (12 generator
    modules: string, number, integer, boolean, enum, email, url, uuid,
    date, timestamp, array, object), `src/generator.mjs`, `src/cli.mjs`
    (hand-rolled argv parser, shebanged, bin-wired), `src/index.mjs`.
  - 6 test files × 49 assertions, all green.
  - `scripts/run-smoke.mjs` runs 6 CLI cases (3 fixtures × {json, jsonl}),
    asserts record count + parseability + byte-identical seed stability.
    All 6 pass.
  - 3 realistic fixtures (users, products with custom alphabet, events
    with nested object + nested url/timestamp).
  - README has every type table row, every CLI flag, three worked
    examples with **actual captured output** (not hand-written).

## What broke

- Node 25 (current default on dev machine) rejects the directory form
  `node --test test/` with `MODULE_NOT_FOUND`. Fixed by switching the
  `test` script to `node --test test/*.test.mjs`. Minor — took 20 seconds
  to diagnose, but it's the kind of thing a real dispatched phase agent
  could easily have shipped as-broken. Noted in phase-5 retro so future
  Node-dispatch phase prompts can pre-empt it.

- Dispatch was again **simulated** (Eternal worker as stand-in). The
  running Tado binary still predates the new STEP 5.5 architect prompt;
  real end-to-end exercise requires the user to relaunch Tado so the new
  architect code is live. Static verification: the Swift edit compiles
  and the prompt text reads correctly; functional verification of STEP
  5.5 itself has to wait for sprint 3.

## Next improvement

Metrics so far: sprint 1 = 0.925, sprint 2 = 0.938. One rung change, +0.013
— inside the ±0.03 plateau window, so the plateau-promotion rule says we
could consider Rung 3 next sprint. But the drift-prevention value of STEP
5.5 hasn't yet been validated against a real architect run, so I'd hold on
the current rung if dispatch still hasn't been exercised against the new
binary. Candidate next sprint:

- **Rung 3 — Skill-creator refinements.** Tighten
  `~/.claude/skills/tado-dispatch-skill-creator/SKILL.md`: crisper "what
  NOT to do" block, stricter acceptance-criteria propagation into the
  emitted phase SKILL.md (so the phase-level skill file also surfaces the
  dispatch.md acceptance criteria verbatim, as a second line of defence
  after STEP 5.5's audit).

If sprint 3 can get a real dispatched architect run on the new binary
(user-triggered), stay on Rung 2 for one more loop to actually measure
the drift fix.
