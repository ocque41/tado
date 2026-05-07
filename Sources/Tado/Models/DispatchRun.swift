import Foundation
import SwiftData

/// One invocation of Dispatch — architect plans N phases from a brief, then
/// phase tiles run sequentially. Replaces the single `dispatch*` state block
/// on `Project`. A project can now hold N `DispatchRun`s concurrently; each
/// owns its own `.tado/dispatch/runs/<id>/` directory and namespaces its
/// per-phase skill/agent files under `.claude/skills/dispatch-<projectslug>-<shortid>-*`
/// so two concurrent dispatches in the same project can't clobber each other's
/// skill definitions.
///
/// Simpler than EternalRun: no mode split, no loop kind, no completion marker,
/// no watchdog. `completed` is reserved as a state the UI archive flow can
/// target even if Tado never auto-sets it.
@Model
final class DispatchRun {
    var id: UUID
    var project: Project?

    var label: String
    var createdAt: Date
    var archivedAt: Date?

    /// `drafted | planning | ready | dispatching | completed`.
    var state: String = "drafted"
    /// User's plain-language brief. Persisted here so the `drafted` state can
    /// be reopened in the modal without touching the filesystem. After Accept
    /// the authoritative copy is `dispatch.md` on disk.
    var brief: String = ""

    /// TodoID of the architect tile (one-shot planner). Soft cache; can be
    /// rebuilt from sessions via `dispatchRunID == run.id && runRole == "architect"`.
    var architectTodoID: UUID?
    /// TodoID of the current phase's tile. Updated by `startPhaseOne` at kickoff;
    /// subsequent phase handoffs via `tado-deploy` do NOT update this (out of
    /// scope for v1 — the tile chain is readable on the canvas without Swift
    /// tracking every hop).
    var currentPhaseTodoID: UUID?

    /// `grid` (default — today's behavior, all tiles flow into the canvas
    /// grid via `CanvasLayout.position(forIndex:)`) or `kanban` (the run's
    /// architect tile + every phase tile snap into named columns drawn on
    /// the canvas, one column per phase, with the architect parked in
    /// column 0). Defaults to `grid` so every existing `DispatchRun`
    /// decodes unchanged after schema bump (additive migration). Picked
    /// in `DispatchFileModal` and consumed by `DispatchPlanService.spawn*`
    /// + `CanvasView`'s per-zone layout.
    var dispatchMode: String = "grid"

    /// TodoID of the coordinator tile that proposed this run via the
    /// natural-language `tado <brief>` path. Nil for runs created via
    /// the project UI's "New Dispatch" button. Mirrors the audit field
    /// on `EternalRun`.
    var spawnedByCoordinatorTodoID: UUID?

    init(
        id: UUID = UUID(),
        project: Project?,
        label: String,
        createdAt: Date = Date(),
        state: String = "drafted",
        brief: String = "",
        architectTodoID: UUID? = nil,
        currentPhaseTodoID: UUID? = nil,
        dispatchMode: String = "grid"
    ) {
        self.id = id
        self.project = project
        self.label = label
        self.createdAt = createdAt
        self.state = state
        self.brief = brief
        self.architectTodoID = architectTodoID
        self.currentPhaseTodoID = currentPhaseTodoID
        self.dispatchMode = dispatchMode
    }
}

extension DispatchRun {
    /// Default label factory. `"Dispatch 2026-04-20 14:30"` local-time.
    static func defaultLabel(createdAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Dispatch \(formatter.string(from: createdAt))"
    }

    /// First 8 hex chars of the UUID. Used as the namespacing suffix in
    /// `.claude/skills/dispatch-<projectslug>-<shortid>-<phase-id>/SKILL.md`
    /// and the corresponding agent paths. 2^32 collision space per project,
    /// enough for realistic N (single digits) by many orders of magnitude.
    /// A guard in `DispatchPlanService.spawnArchitect` detects the freakishly
    /// improbable collision and bumps to 10 chars rather than silently
    /// overwriting a running dispatch's files.
    var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
