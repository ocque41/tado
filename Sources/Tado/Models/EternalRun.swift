import Foundation
import SwiftData

/// One invocation of the Eternal feature — Mega or Sprint — for a project.
/// Replaces the single `eternal*` state block that previously lived on
/// `Project`. A project can now hold N `EternalRun`s concurrently; each
/// owns its own `.tado/eternal/runs/<id>/` directory, its own worker +
/// architect + interventor tiles, and its own hook state. Hooks share
/// the project-level `.tado/eternal/hooks/` script dir and key off the
/// `TADO_ETERNAL_RUN_ID` env var to find the correct run dir at invocation.
///
/// SwiftData stores only the orchestration fields; iteration counters,
/// metrics history, and last-activity timestamps live in on-disk
/// `state.json` / `metrics.jsonl`. Duplicating those in SwiftData was the
/// old single-run model's biggest drift source — not repeating the mistake.
@Model
final class EternalRun {
    var id: UUID
    /// Cascade-deleted when the parent project is removed. On-disk
    /// `.tado/eternal/runs/<id>/` is NOT cleaned up — matches the pre-
    /// multi-run behavior where `.tado/eternal/` survived project deletion.
    var project: Project?

    /// User-editable display name. Default at creation: `"Sprint 2026-04-20 14:30"` /
    /// `"Mega 2026-04-20 14:30"`. Shown in the project detail list, in canvas
    /// tile tooltips, and in the Intervene modal title so the user never
    /// misclicks across concurrent runs.
    var label: String
    var createdAt: Date
    /// Set when the user archives a completed/stopped run. `nil` = active or
    /// still visible. Persisted as `Date?` so future archive-sort UX is free.
    var archivedAt: Date?

    // MARK: - State (mirrors what was on Project)

    /// `drafted | planning | awaitingReview | ready | running | completed | stopped`.
    /// `awaitingReview` is the gate between architect (writes `crafted.md`)
    /// and worker (reads `crafted.md`). Set by `RunEventWatcher` when both
    /// `crafted.md` and `plan.json` are on disk; cleared by `acceptReview`.
    var state: String = "drafted"
    /// `mega | sprint`.
    var mode: String = "mega"

    /// How the worker is kept alive turn-to-turn.
    ///
    /// - `external` (default, "normal session"): spawns
    ///   `.tado/eternal/hooks/eternal-loop.sh`, which re-invokes
    ///   `claude -p "<prompt>"` each iteration. Fresh context per turn
    ///   (cheap tokens, no mid-turn memory). Claude Code's in-session
    ///   Stop-hook recursion counter resets every cycle, so the loop
    ///   never dies from recursion limits.
    /// - `internal` ("continuous session"): spawns ONE interactive
    ///   `claude --permission-mode auto` session. The session stays
    ///   alive for its whole lifetime; context grows across turns and
    ///   auto-compacts. Continuation is driven by (1) Tado's idle-
    ///   detection injecting a "continue" prompt each time the session
    ///   goes `.needsInput`, AND (2) a `/loop 30s continue …` command
    ///   typed after the first turn so Claude Code's own scheduler
    ///   backs up Tado's injection. Requires Claude Code auto mode
    ///   (shipped late Apr 2026) — the old stop-hook-blocking trick
    ///   tripped Claude Code's recursion counter and is gone.
    var loopKind: String = "external"

    /// String Claude outputs to let the Stop hook exit cleanly.
    var completionMarker: String = "ETERNAL-DONE"
    /// Sprint-only: natural-language "how to evaluate each sprint".
    var sprintEval: String = ""
    /// Sprint-only: natural-language "what to change next based on results".
    var sprintImprove: String = ""
    /// When true, worker spawns with `--dangerously-skip-permissions`.
    var skipPermissions: Bool = true

    /// Engine the architect / worker / interventor run on. `"claude"` (the
    /// default) keeps every existing run on disk behaving as before; new
    /// runs created via the Eternal sheet pick this up from `AppSettings`.
    /// Stored as a string for SwiftData simplicity, paralleling `mode`
    /// and `loopKind`. Resolved through `TerminalEngine(rawValue:)` at
    /// spawn time.
    var engine: String = "claude"

    /// `general` (default — today's behavior) or `perf` (Performance step
    /// active). Orthogonal to `mode` and `loopKind`. When `"perf"`, the
    /// architect prompt's `## PERFORMANCE` section is generated, the
    /// worker env carries `TADO_PERF_MODE=1`, and `stop.sh` enforces
    /// the same-turn pay-back contract: `[SPRINT-DONE]` and
    /// `ETERNAL-DONE` are blocked unless `[PERF-OK]` precedes them in
    /// the same turn's transcript. Backed by the new `tado-core/crates/
    /// perf-suite/` measurement harness.
    var kind: String = "general"

    /// Raw plain-language brief the user wrote in the modal. Persisted here
    /// so the `drafted` state can be reopened in the modal without touching
    /// the filesystem. The authoritative brief after Accept is `crafted.md`
    /// on disk; this string is only the editable source.
    var userBrief: String = ""

    /// TodoID of the worker tile. Soft cache — can be rebuilt by filtering
    /// `terminalManager.sessions` on `eternalRunID == run.id && runRole == "worker"`.
    /// If it diverges from a session's actual `eternalRunID`, the session's
    /// value is authoritative. Set by `spawnWorker`, cleared on stop/reset.
    var workerTodoID: UUID?
    /// TodoID of the architect tile. Same soft-cache contract as `workerTodoID`.
    var architectTodoID: UUID?

    /// TodoID of the coordinator tile that proposed this run via the
    /// natural-language `tado <brief>` path on the general todo page.
    /// Nil for runs created via the project UI's "New Mega/Sprint" buttons.
    /// Used by Cross-Run Browser to badge coordinator-spawned runs and link
    /// back to their originating todo for audit.
    var spawnedByCoordinatorTodoID: UUID?

    init(
        id: UUID = UUID(),
        project: Project?,
        label: String,
        createdAt: Date = Date(),
        state: String = "drafted",
        mode: String = "mega",
        loopKind: String = "external",
        completionMarker: String = "ETERNAL-DONE",
        sprintEval: String = "",
        sprintImprove: String = "",
        skipPermissions: Bool = true,
        engine: String = "claude",
        kind: String = "general",
        userBrief: String = "",
        workerTodoID: UUID? = nil,
        architectTodoID: UUID? = nil
    ) {
        self.id = id
        self.project = project
        self.label = label
        self.createdAt = createdAt
        self.state = state
        self.mode = mode
        self.loopKind = loopKind
        self.completionMarker = completionMarker
        self.sprintEval = sprintEval
        self.sprintImprove = sprintImprove
        self.skipPermissions = skipPermissions
        self.engine = engine
        self.kind = kind
        self.userBrief = userBrief
        self.workerTodoID = workerTodoID
        self.architectTodoID = architectTodoID
    }
}

extension EternalRun {
    /// Default label factory. Called by "New Mega"/"New Sprint" buttons and
    /// by the one-shot migration that lifts legacy `Project.eternal*` blocks
    /// into a first `EternalRun`. The date format is local-time
    /// `yyyy-MM-dd HH:mm` so runs created at 14:30 read naturally in the UI;
    /// timezone drift across machines is acceptable because this is a
    /// display-only string.
    static func defaultLabel(mode: String, createdAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = mode == "sprint" ? "Sprint" : "Mega"
        return "\(title) \(formatter.string(from: createdAt))"
    }

    /// First 8 hex chars of the UUID. Unused for Eternal today (Eternal runs
    /// don't write per-run skill/agent files), but exposed for parity with
    /// `DispatchRun.shortID` so UI code that labels tiles can treat both
    /// kinds uniformly.
    var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
