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

    /// `drafted | planning | ready | running | completed | stopped`.
    var state: String = "drafted"
    /// `mega | sprint`.
    var mode: String = "mega"
    /// String Claude outputs to let the Stop hook exit cleanly.
    var completionMarker: String = "ETERNAL-DONE"
    /// Sprint-only: natural-language "how to evaluate each sprint".
    var sprintEval: String = ""
    /// Sprint-only: natural-language "what to change next based on results".
    var sprintImprove: String = ""
    /// When true, worker spawns with `--dangerously-skip-permissions`.
    var skipPermissions: Bool = true

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

    init(
        id: UUID = UUID(),
        project: Project?,
        label: String,
        createdAt: Date = Date(),
        state: String = "drafted",
        mode: String = "mega",
        completionMarker: String = "ETERNAL-DONE",
        sprintEval: String = "",
        sprintImprove: String = "",
        skipPermissions: Bool = true,
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
        self.completionMarker = completionMarker
        self.sprintEval = sprintEval
        self.sprintImprove = sprintImprove
        self.skipPermissions = skipPermissions
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
