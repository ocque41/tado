# sprint-suite ↔ Tado integration

The Rust harness is complete; this doc captures the **Swift glue**
needed in the Tado app to wire `EternalRun.kind = "sprint"` through
to a working worker prompt + Stop-hook gate. Apply these edits to
finish the v1.3 release.

## Why this doc exists

While building this feature against the live working tree, a
concurrent Claude Code session (running in plan-mode with file
watchers) repeatedly reverted Swift edits faster than they could be
committed. The Rust core, `EternalState` schema, the on-disk
`sprint-gate.sh` hook, and the worker `SKILL.md` all landed
successfully in commits 9c77b53 and 5eddcc8. The remaining Swift
edits below need to be applied in one pass when no concurrent
session is active.

## 1. ProcessSpawner.swift — three small additions

### 1a. `eternalWorkerEnv` — add `sprintMode: Bool = false` parameter

Locate the function signature (around line 1731):

```swift
        codexPostFlags: [String]? = nil,
        perfMode: Bool = false
    ) -> [String: String] {
```

Change to:

```swift
        codexPostFlags: [String]? = nil,
        perfMode: Bool = false,
        sprintMode: Bool = false
    ) -> [String: String] {
```

Then inside the body, after the existing `if perfMode { … }` block:

```swift
        if perfMode {
            env["TADO_PERF_MODE"] = "1"
        }
        if sprintMode {
            env["TADO_SPRINT_MODE"] = "1"
        }
```

### 1b. `eternalMegaPrompt` and `eternalSprintPrompt` — add `sprintMode: Bool = false`

Both functions (around lines 1875 and 2030) take `perfMode: Bool = false`
already. Add the parallel parameter:

```swift
    static func eternalMegaPrompt(
        ...,
        perfMode: Bool = false,
        sprintMode: Bool = false
    ) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        let perfStep = perfMode ? eternalPerfStepBlock(runDir: runDir, marker: marker, sprintMarker: nil) : ""
        let sprintStep = sprintMode ? eternalSprintStepBlock(runDir: runDir, marker: marker, sprintMarker: nil) : ""
```

Then in the prompt body, just before `\(eternalNonStopHygiene(...))`:

```swift
        \(perfStep)
        \(sprintStep)

        \(eternalNonStopHygiene(engine: engine, runDir: runDir))
```

For `eternalSprintPrompt`, also update the `evalLine` ternary into a
three-way switch so the metrics.jsonl shape names sprint components
(velocity, code_review_passes, bugs_penalty, satisfaction) when
sprintMode is true.

### 1c. Add `eternalSprintStepBlock` and `eternalSprintArchitectAddendum`

Two new private static funcs that mirror the perf siblings. The
sprint step block is the prose the worker sees in every iteration;
the architect addendum is what teaches the architect to seed
`sprint_rules.txt` / `sprint-data.json` / `prepare.py` and write
the `## SPRINT RULES OPTIMIZATION` section in `crafted.md`. Full
contents are in `tado-core/crates/sprint-suite/INTEGRATION-prompts.md`.

### 1d. `eternalArchitectPrompt` — branch on kind

```swift
        let isSprint = (mode == "sprint")
        let isPerf = (kind == "perf")
        let isSprintKind = (kind == "sprint")
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        let perfBriefAddendum = isPerf ? eternalPerfArchitectAddendum(...) : ""
        let sprintBriefAddendum = isSprintKind ? eternalSprintArchitectAddendum(projectName: projectName, projectRoot: projectRoot, runDir: runDir, isSprintMode: isSprint) : ""
```

Splice `\(sprintBriefAddendum)` right after `\(perfBriefAddendum)`
in the architect prompt body.

## 2. EternalService.swift — three small additions

### 2a. `hookScripts` — register `sprint-gate.sh`

```swift
    private static let hookScripts: [(String, String)] = [
        ("stop.sh", stopScript),
        ("session-start-compact.sh", sessionStartCompactScript),
        ("pre-compact.sh", preCompactScript),
        ("post-tool.sh", postToolScript),
        ("eternal-loop.sh", workerLoopScript),
        ("perf-gate.sh", perfGateScript),
        ("sprint-gate.sh", sprintGateScript),
    ]
```

### 2b. Add `sprintGateScript` literal

Append after `perfGateScript` in the same `// MARK: - Hook bodies`
section. Full contents in `.tado/eternal/hooks/sprint-gate.sh` (the
canonical on-disk version landed in this commit).

### 2c. Add sprint enforcement block to `stopScript`

Mirror of the perf-gate enforcement block. Inserts between the
existing perf block and the "Completion marker" branch. Full text
in `.tado/eternal/hooks/stop.sh` (the canonical on-disk version
landed in this commit).

### 2d. `spawnEternalWorker` — pass `sprintMode` to ProcessSpawner

```swift
        let perfMode = (run.kind == "perf")
        let sprintMode = (run.kind == "sprint")
        if run.mode == "sprint" {
            prompt = ProcessSpawner.eternalSprintPrompt(
                ...,
                perfMode: perfMode,
                sprintMode: sprintMode
            )
        } else {
            prompt = ProcessSpawner.eternalMegaPrompt(
                ...,
                perfMode: perfMode,
                sprintMode: sprintMode
            )
        }
```

## 3. MetalTerminalTileView.swift — pass sprintMode through env

```swift
            let eternalEnv = ProcessSpawner.eternalWorkerEnv(
                ...,
                perfMode: (session.eternalKind == "perf"),
                sprintMode: (session.eternalKind == "sprint")
            )
```

## 4. EternalFileModal.swift — third kind button

The existing kind picker (around line 232) has two buttons:
"General" and "Performance". Add a third:

```swift
            HStack(spacing: 8) {
                kindButton(label: "General", value: "general")
                kindButton(label: "Performance", value: "perf")
                kindButton(label: "Sprint", value: "sprint")
                Spacer()
            }
```

Update `kindSubtitle` to handle `kind == "sprint"`:

```swift
    private var kindSubtitle: String {
        switch kind {
        case "perf":
            return "Performance step active. ..."
        case "sprint":
            return "Sprint step active. Each iteration proposes ONE change to sprint_rules.txt, records a measured row in sprint-data.json, and runs sprint-gate.sh which scores the SprintSuccessScore (velocity*100 + reviews*2 - bugs*10 + satisfaction*5) against the project's all-time-best baseline at .tado/sprint-baselines/<project>.json. The worker MUST clear the sprint gate ([SCORE-OK]) before printing [SPRINT-DONE] or ETERNAL-DONE."
        default:
            return "Default Eternal behavior — the architect designs the brief, the worker iterates per the chosen mode, no gate active."
        }
    }
```

Update the persistence path (around line 483):

```swift
    run.kind = ["general", "perf", "sprint"].contains(kind) ? kind : "general"
```

## 5. RunEventWatcher.swift — emit sprint cycle events

Mirror the perf cycle handler (around line 305). When
`newState.sprintCycles > old.sprintCycles`:

- Emit `eternalSprintImproved` / `eternalSprintHeld` /
  `eternalSprintRegressed` TadoEvent (add three new cases in
  `Events/TadoEvent.swift`).
- Mirror a Dome retro under `kind: "eternal-sprint"` with the
  composite + the offending sub-metric on regression.

## Verification

After applying all edits:

```bash
cd tado-core && cargo test -p sprint-suite       # 12/12 should pass
swift build                                      # should be clean
bash .tado/eternal/hooks/sprint-gate.sh          # without TADO_SPRINT_MODE=1 → "SCORE: NOT-SPRINT-MODE"
```

Then manually create a run via the New Eternal modal with
`Kind = Sprint`, watch a sprint-data.json appear in the project
root, watch `[SCORE-OK]` lines in the worker tile, and confirm
`.tado/sprint-baselines/<project>.json` ratchets monotonically.
