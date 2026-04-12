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

enum ClaudeMode: String, Codable, CaseIterable {
    case askPermissions
    case autoAcceptEdits
    case planMode
    case bypassPermissions

    var displayName: String {
        switch self {
        case .askPermissions: "Ask permissions"
        case .autoAcceptEdits: "Auto accept edits"
        case .planMode: "Plan mode"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    var cliFlags: [String] {
        switch self {
        case .askPermissions:    return ["--permission-mode", "default"]
        case .autoAcceptEdits:   return ["--permission-mode", "acceptEdits"]
        case .planMode:          return ["--permission-mode", "plan"]
        case .bypassPermissions: return ["--permission-mode", "bypassPermissions"]
        }
    }
}

enum CodexMode: String, Codable, CaseIterable {
    case defaultPermissions
    case fullAccess
    case custom

    var displayName: String {
        switch self {
        case .defaultPermissions: "Default permissions"
        case .fullAccess: "Full access"
        case .custom: "Custom (config.toml)"
        }
    }

    var cliFlags: [String] {
        // --no-alt-screen: Tado is a terminal multiplexer; alternate screen
        // breaks Codex's command execution in embedded SwiftTerm tiles.
        // env inherit: ensure Tado IPC vars reach tado-send subprocesses.
        let base = ["--no-alt-screen", "-c", "shell_environment_policy.inherit=all"]
        switch self {
        case .defaultPermissions: return base
        case .fullAccess:         return ["--ask-for-approval", "never", "--sandbox", "danger-full-access"] + base
        case .custom:             return base
        }
    }
}

enum ClaudeEffort: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case max

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    var cliFlags: [String] {
        return ["--effort", rawValue]
    }
}

enum CodexEffort: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case xhigh

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        }
    }

    var cliFlags: [String] {
        return ["-c", "model_reasoning_effort=\"\(rawValue)\""]
    }
}

@Observable
@MainActor
final class AppState {
    var currentView: ViewMode = .todoList
    var showSettings: Bool = false
    var showSidebar: Bool = false
    var showDoneList: Bool = false
    var showTrashList: Bool = false
    var pendingNavigationID: UUID? = nil
    var forwardTargetTodoID: UUID? = nil
}
