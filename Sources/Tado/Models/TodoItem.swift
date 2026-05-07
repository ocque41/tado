import Foundation
import SwiftData

enum ListState: String {
    case active
    case done
    case trashed
}

@Model
final class TodoItem {
    var id: UUID
    var text: String
    var createdAt: Date
    var isComplete: Bool
    var canvasX: CGFloat
    var canvasY: CGFloat
    /// Persisted tile size. Defaults match `CanvasLayout.contentWidth/
    /// contentHeight` so freshly-created todos land at the same size
    /// the renderer used before v0.18; on relaunch the in-memory
    /// `TerminalSession.tileWidth/tileHeight` is rehydrated from these
    /// fields so the user's manual resizes survive a quit. SwiftData
    /// lightweight migration auto-fills both columns with their
    /// defaults for pre-v0.18 rows — no migration step required.
    var tileWidth: CGFloat = CanvasLayout.contentWidth
    var tileHeight: CGFloat = CanvasLayout.contentHeight
    var gridIndex: Int
    var terminalSessionID: UUID?
    var statusRaw: String = SessionStatus.pending.rawValue
    var listStateRaw: String = ListState.active.rawValue
    var cwd: String?
    var terminalLog: String = ""
    var projectID: UUID?
    var teamID: UUID?
    var agentName: String?
    var name: String?
    /// Set on todos created by the natural-language coordinator path
    /// in `TodoListView` when the user types `tado <brief>`. The
    /// spawned tile receives `ProcessSpawner.coordinatorPrompt` instead
    /// of the user text directly, becomes a Tado-CLI-driving Claude
    /// agent that interprets the brief, drives Eternal/Dispatch/etc.,
    /// supervises through the human-review gate, accepts on the user's
    /// behalf, and exits. Default false; lightweight SwiftData
    /// migration auto-fills false on existing rows.
    var isCoordinator: Bool = false
    /// Soft pointer to a `KanbanColumn.columnKey` when this todo is
    /// rendered as a card on the project's general Kanban board.
    /// `nil` means "not on the board" — equivalent to a virtual
    /// "Backlog" lane the UI synthesizes for unassigned cards. Cards
    /// on a kanban-mode dispatch run's canvas are positioned by the
    /// session's `dispatchRunID` + `runRole` instead, NOT by this
    /// field; this field is exclusively for the project page's
    /// Detail|Kanban toggle. Lightweight SwiftData migration leaves
    /// this nil on every pre-existing row.
    var kanbanColumnKey: String?
    /// Sort order within a Kanban column. Lower first. Used by the
    /// per-project board's lane rendering and updated by drag-and-drop
    /// reorders. Lightweight SwiftData migration defaults to 0 on
    /// pre-existing rows; the board view rebuilds densities lazily.
    var kanbanOrderIndex: Int = 0
    static let maxLogSize = 256 * 1024

    init(text: String, gridIndex: Int, canvasPosition: CGPoint) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.isComplete = false
        self.canvasX = canvasPosition.x
        self.canvasY = canvasPosition.y
        self.gridIndex = gridIndex
        self.terminalSessionID = nil
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var listState: ListState {
        get { ListState(rawValue: listStateRaw) ?? .active }
        set { listStateRaw = newValue.rawValue }
    }

    var canvasPosition: CGPoint {
        CGPoint(x: canvasX, y: canvasY)
    }

    var displayName: String {
        name ?? text
    }

    var gridLabel: String {
        let col = gridIndex % 3 + 1
        let row = gridIndex / 3 + 1
        return "[\(col), \(row)]"
    }
}
