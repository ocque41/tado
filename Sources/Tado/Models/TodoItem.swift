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
