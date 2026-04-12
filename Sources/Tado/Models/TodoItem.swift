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
    var gridIndex: Int
    var terminalSessionID: UUID?
    var statusRaw: String = SessionStatus.pending.rawValue
    var listStateRaw: String = ListState.active.rawValue
    var cwd: String?
    var terminalLog: String = ""
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

    var gridLabel: String {
        let col = gridIndex % 3 + 1
        let row = gridIndex / 3 + 1
        return "[\(col), \(row)]"
    }
}
