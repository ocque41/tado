import SwiftUI

enum ViewMode: Equatable {
    case todoList
    case canvas
}

enum TerminalEngine: String, Codable, CaseIterable {
    case claude = "claude"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

@Observable
@MainActor
final class AppState {
    var currentView: ViewMode = .todoList
    var showSettings: Bool = false
    var showSidebar: Bool = false
    var pendingNavigationID: UUID? = nil
    var forwardTargetTodoID: UUID? = nil
}
