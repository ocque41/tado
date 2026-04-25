# Feature migrations: Eternal / Dispatch / Notifications → Extensions

Tado's core thesis — "terminal multiplexer for AI agents on a
canvas" — is proven. The `foundation-v2` branch is about making
the app smaller by moving optional features out of core and into
bundled extensions, so future features can ship as extensions
instead of bloating core too.

T6 is the doc phase: which features move, in what order, with what
success criteria. Actual migrations happen as separate commits on
`foundation-v2` (or follow-up branches) because each has its own
shape and test surface.

## Candidates

| Feature            | Current home                                  | Move to extension? | Why                                                                                     |
|--------------------|-----------------------------------------------|--------------------|-----------------------------------------------------------------------------------------|
| Eternal            | `Sources/Tado/Services/EternalService.swift`  | Yes                | Optional workflow — some users never touch it. Extension keeps core launchable without. |
| Dispatch           | `Sources/Tado/Services/DispatchPlanService.swift` | Yes            | Same reasoning as Eternal.                                                              |
| Notifications      | `Sources/Tado/Views/NotificationsView.swift`  | Yes                | Historical log + banner viewer. Useful but not on the golden path.                      |
| Projects           | `Sources/Tado/Views/Projects/*`               | **No** (for now)   | Central navigation surface; moving it would require reshaping the sidebar.              |
| Canvas + terminals | `Sources/Tado/Views/CanvasView.swift` etc.    | No                 | This _is_ core.                                                                         |
| IPC broker         | `Sources/Tado/Services/IPCBroker.swift`       | No                 | Core. (Rust port lives in `tado-ipc`; see T2.)                                          |

## Migration shape

Per feature, one commit on `foundation-v2`:

1. Create `Sources/Tado/Extensions/<id>/` with
   - `<Name>Extension.swift` conforming to `AppExtension`
     (manifest id like `"eternal"`, SF Symbol, default window size).
   - `<Name>View.swift` — the existing feature's root view, moved.
   - Any `*Support.swift` helpers stay alongside if they're
     feature-local.
2. Register the extension in `ExtensionRegistry.all` and add a
   matching `WindowGroup(id: ExtensionWindowID.string(for: ...))`
   block in `TadoApp.body`.
3. Remove the feature's entry point from the main window's
   navigation / sidebar. Inline wiring that referenced feature
   internals gets replaced with a "Open in window" button that
   calls `@Environment(\.openWindow)`.
4. Verify: `swift build` green, `swift test` green, feature
   still works end-to-end when opened from the Extensions
   surface.

## Deliberate non-goal: feature flags

No feature-flag scaffolding. Extensions are bundled; the `.app`
user either gets the extension or the `.app` doesn't ship it.
Adding flags would re-import the complexity we're trying to shed.

## Deliberate non-goal: watchdogs / retries

Per `feedback_no_dispatch_safety_systems` memory: **no new**
watchdogs, timeouts, or auto-retry around dispatch. Moving
Dispatch to an extension preserves its existing orchestration
exactly as-is; the extension wrapper is pure packaging.

## Order we'd pick

1. **Notifications first**. Smallest surface; single SwiftUI view
   with very few external dependencies. Validates the end-to-end
   migration pattern on the shortest possible loop.
2. **Eternal second**. Bigger service + view bundle, but the
   workflow is well-scoped; success criteria are crisp (run an
   Eternal run from the extension window, confirm
   `.tado/eternal/runs/…` state still updates identically).
3. **Dispatch third**. Same pattern as Eternal; benefit from
   lessons learned.

Projects view stays in core for this foundation-v2 pass; revisit
once Dome ships and we have real cross-app UX feedback.

## Why this sits at T6 as "roadmap only"

Each migration is ~200-500 LOC of Swift surgery per feature with
careful test verification. Done right, each deserves its own
commit with a full before/after diff and its own test run.
foundation-v2 is already a long branch with significant structural
work (T1 workspace split, T2 tado-ipc, T3 tado-settings, T5
extensions host). Writing the plan now and executing each migration
as a follow-up commit keeps each diff reviewable and keeps the
final squash-merge (T8) readable.

## Decision log

- 2026-04-22 — roadmap written (T6 of foundation-v2). Actual
  migrations are follow-ups, committed one feature per commit.
- 2026-04-22 — Notifications migrated as the H5 commit. Pattern
  validated: extension type + window view + scene wiring + caller
  swap from sheet to openWindow.
- 2026-04-22 — Eternal and Dispatch reclassified out of the
  "migrate to extension" list. The existing surfaces
  (`EternalFileModal`, `EternalInterveneModal`,
  `DispatchFileModal`) are *per-run contextual editors* — they
  require a specific run id and only make sense in the context of
  one project's one run, opened from the project view's run row.
  Extracting them into standalone-window extensions would
  duplicate the run-context plumbing without a UX win, and the
  resulting "extension" wouldn't meaningfully differ from the
  current sheet (still per-run, still bound to a project).
  Notifications worked as an extension because it's a single
  global view of `EventBus.shared.recent` — no context to thread
  through. The right *new* extension would be an Eternal Run
  Browser / Dispatch History surface that aggregates across runs;
  that's a new feature, not a migration, and lands as its own
  scoped commit when the user wants it.
