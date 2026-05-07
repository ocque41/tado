import Foundation
import SwiftData

/// A column in a Kanban board. Two flavors:
///
/// - `kind == "project"` — user-managed columns on a project's general
///   Kanban board (the per-project page-mode toggle "Detail | Kanban").
///   Cards are `TodoItem`s whose `kanbanColumnKey == columnKey`. Order
///   within a board is `orderIndex` ascending; the board view seeds
///   `Backlog / Doing / Done` on first visit.
///
/// - `kind == "dispatch-phase"` — auto-managed, one row per phase of a
///   `DispatchRun` whose `dispatchMode == "kanban"`. Anchors a phase
///   tile to a vertical lane on the canvas. `dispatchRunID` points back
///   at the run; `orderIndex` mirrors the phase JSON's `order` field.
///   Materialized by `DispatchPlanService.materializeKanbanColumns`
///   when the architect writes `plan.json` (triggered from
///   `RunEventWatcher`).
///
/// `columnKey` is the stable identifier used everywhere off-database
/// (CLI args, mirror JSON, drag-and-drop). Format:
///   - "project" kind: short slug — "backlog", "doing", "done", "review", …
///   - "dispatch-phase" kind: "<run.shortID>-<phase.order>" — e.g. "a1b2c3d4-1"
@Model
final class KanbanColumn {
    var id: UUID
    var project: Project?

    var kind: String = "project"
    var columnKey: String
    var title: String
    var orderIndex: Int = 0
    var dispatchRunID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        project: Project?,
        kind: String = "project",
        columnKey: String,
        title: String,
        orderIndex: Int = 0,
        dispatchRunID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.project = project
        self.kind = kind
        self.columnKey = columnKey
        self.title = title
        self.orderIndex = orderIndex
        self.dispatchRunID = dispatchRunID
        self.createdAt = createdAt
    }
}

extension KanbanColumn {
    /// Default "project" columns seeded on a project's first Kanban
    /// visit. Order matches the visual flow left→right.
    static let defaultProjectColumns: [(key: String, title: String)] = [
        (key: "backlog", title: "Backlog"),
        (key: "doing", title: "Doing"),
        (key: "done", title: "Done"),
    ]

    /// Build the `columnKey` for a "dispatch-phase" row. Stable across
    /// architect re-plans because the run's shortID never changes — only
    /// the phase contents do — so a re-plan re-uses the same column
    /// rows where the order overlaps and only inserts/removes deltas.
    static func dispatchPhaseColumnKey(runShortID: String, order: Int) -> String {
        "\(runShortID)-\(order)"
    }
}
