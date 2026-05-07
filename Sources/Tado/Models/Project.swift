import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    var dispatchMarkdown: String = ""
    /// State machine for the project's dispatch lifecycle.
    /// `idle` → no dispatch started.
    /// `drafted` → user typed a brief in the modal but hasn't hit Accept yet
    /// (used by the modal to prefill on reopen).
    /// `planning` → architect is running, no plan on disk yet (or incomplete).
    /// `dispatching` → plan is on disk, phase 1+ running, chain alive.
    var dispatchState: String = "idle"

    // MARK: - Eternal
    /// Non-stop single-agent session (ralph-loop pattern). Independent of Dispatch.
    var eternalMarkdown: String = ""
    /// `idle | drafted | running | completed | stopped`.
    var eternalState: String = "idle"
    /// `mega | sprint`.
    var eternalMode: String = "mega"
    /// String Claude outputs to let the Stop hook exit cleanly.
    var eternalCompletionMarker: String = "ETERNAL-DONE"
    /// Sprint-only: natural-language "how to evaluate each sprint".
    var eternalSprintEval: String = ""
    /// Sprint-only: natural-language "what to change next based on results".
    var eternalSprintImprove: String = ""
    /// When true, spawn with `--dangerously-skip-permissions` instead of
    /// `--permission-mode bypassPermissions`. Required for truly non-stop
    /// operation — bypassPermissions still refuses commands Claude Code
    /// considers dangerous, which halts a ralph-loop. Defaults true because
    /// that's what Eternal promises on the tin; users who want a paranoid
    /// loop can flip Full Auto off in the brief editor.
    ///
    /// Existing projects get migrated to `true` on first launch via
    /// `AppSettings.didMigrateEternalDefaults` + `runStartupMigrations`.
    var eternalSkipPermissions: Bool = true

    /// How the eternal worker is kept alive turn-to-turn.
    ///
    /// - `external` (default): `eternal-loop.sh` runs `claude -p "<prompt>"`
    ///   headless; process exits at turn-end; wrapper re-reads crafted.md /
    ///   progress.md / inbox and relaunches. Cheap tokens (fresh context
    ///   each iter), no mid-turn reasoning — reads like "bash + conclusion."
    /// - `internal`: `eternal-session-loop.sh` launches ONE interactive
    ///   `claude` session; the Stop hook returns `{decision:"block"}` on
    ///   every turn-end, so context grows and auto-compacts (Boris's 1d
    ///   pattern). When Claude Code's recursion counter trips (~20-30
    ///   cycles), the wrapper re-enters via `claude --continue` to preserve
    ///   the conversation. Higher token cost, deep cross-turn reasoning.
    ///
    /// Both modes share the same stop.sh, crafted.md, progress.md, state.json,
    /// and inbox. The only runtime difference is whether the wrapper sets
    /// `TADO_ETERNAL_LOOP_MODE=1` (external) or not (internal) — stop.sh
    /// keys off that env var.
    var eternalLoopKind: String = "external"

    /// TodoID of the Eternal *worker* tile. Set by `EternalService.spawnWorker`
    /// and cleared on stop/complete/reset. The "Watch on Canvas" button in the
    /// Eternal section uses this exact ID so it never navigates to a Dispatch
    /// phase tile that happens to share the project cwd.
    var eternalTodoID: UUID? = nil

    /// TodoID of the Eternal *architect* tile. Set by `spawnArchitect`, cleared
    /// on reset. The `planning` state UI uses this to deep-link to the
    /// architect terminal (not strictly required, but mirrors Dispatch's UX).
    var eternalArchitectTodoID: UUID? = nil

    /// When true, Dome retrievals on this project default to
    /// `knowledge_scope: "project"` instead of `"merged"`, so agents
    /// don't pull in global notes / other projects' codebase chunks
    /// unless the user explicitly asks. The Project Knowledge surface
    /// surfaces this as "Isolate this project from global knowledge",
    /// and the spawn-time preamble appends an extra retrieval-contract
    /// line warning the agent of the isolation.
    ///
    /// Defaults to `false` so existing projects keep the v1.0 merged
    /// behaviour. Stored on the SwiftData model rather than in
    /// `<project>/.tado/local.json` because it's a per-installation
    /// preference, not a committed project setting.
    var scopeIsolation: Bool = false

    // MARK: - Runs (multi-concurrent)
    /// All Eternal runs ever created for this project, including archived
    /// ones. The one-shot `didMigrateToMultipleRuns` migration seeds one
    /// `EternalRun` per project with an active-looking legacy state. New
    /// projects start with an empty list; "New Mega" / "New Sprint" buttons
    /// insert rows.
    ///
    /// Cascade delete: removing a project drops all its runs from SwiftData.
    /// The on-disk `.tado/eternal/runs/<id>/` directories are NOT removed,
    /// matching pre-multi-run behavior where `.tado/eternal/` survived
    /// project deletion.
    @Relationship(deleteRule: .cascade, inverse: \EternalRun.project)
    var eternalRuns: [EternalRun] = []

    /// Dispatch equivalent of `eternalRuns`. Same semantics — cascade delete
    /// in SwiftData, on-disk artefacts survive for forensic purposes.
    @Relationship(deleteRule: .cascade, inverse: \DispatchRun.project)
    var dispatchRuns: [DispatchRun] = []

    init(name: String, rootPath: String) {
        self.id = UUID()
        self.name = name
        self.rootPath = rootPath
        self.createdAt = Date()
    }
}
