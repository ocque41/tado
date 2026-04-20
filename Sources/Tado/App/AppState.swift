import SwiftUI

enum ViewMode: String, CaseIterable, Equatable {
    case canvas
    case projects
    case todos

    var label: String {
        switch self {
        case .canvas: "Canvas"
        case .projects: "Projects"
        case .todos: "Todos"
        }
    }

    var icon: String {
        switch self {
        case .canvas: "square.grid.3x3"
        case .projects: "folder"
        case .todos: "checklist"
        }
    }
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

    /// Mode-specific flags only. The Tado runtime shim
    /// (`--no-alt-screen` and `-c shell_environment_policy.inherit=all`) is added
    /// separately by `ProcessSpawner.codexEmbedShim(allowAlternateScreen:)`
    /// so the alt-screen behavior is user-toggleable via AppSettings.
    var cliFlags: [String] {
        switch self {
        case .defaultPermissions: return []
        case .fullAccess:         return ["--ask-for-approval", "never", "--sandbox", "danger-full-access"]
        case .custom:             return []
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

enum ClaudeModel: String, Codable, CaseIterable {
    case opus47 = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45 = "claude-haiku-4-5"

    var displayName: String {
        switch self {
        case .opus47: "Opus 4.7"
        case .sonnet46: "Sonnet 4.6"
        case .haiku45: "Haiku 4.5"
        }
    }

    /// Claude Code's `--model` flag takes a plain model id. Variants like
    /// `opus[1m]` (1M context) are *not* resolvable through the CLI flag —
    /// the parser rejects the bracketed suffix with "model not found". The
    /// working entry points for 1M are the `/model opus[1m]` slash command,
    /// `settings.json` with `"model": "opus[1m]"`, or the
    /// `ANTHROPIC_MODEL=opus[1m]` env var. None of those belong in the
    /// picker without a dedicated UI, so Tado's picker exposes plain ids
    /// only and the 1M mode is reachable via the shell inside the tile.
    var cliFlags: [String] {
        return ["--model", rawValue]
    }
}

enum CodexModel: String, Codable, CaseIterable {
    case gpt54 = "gpt-5.4"
    case gpt52Codex = "gpt-5.2-codex"
    case gpt51CodexMax = "gpt-5.1-codex-max"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt53Codex = "gpt-5.3-codex"
    case gpt52 = "gpt-5.2"
    case gpt51CodexMini = "gpt-5.1-codex-mini"

    var displayName: String {
        switch self {
        case .gpt54: "GPT-5.4"
        case .gpt52Codex: "GPT-5.2-Codex"
        case .gpt51CodexMax: "GPT-5.1-Codex-Max"
        case .gpt54Mini: "GPT-5.4-Mini"
        case .gpt53Codex: "GPT-5.3-Codex"
        case .gpt52: "GPT-5.2"
        case .gpt51CodexMini: "GPT-5.1-Codex-Mini"
        }
    }

    var cliFlags: [String] {
        return ["-c", "model=\"\(rawValue)\""]
    }
}

@Observable
@MainActor
final class AppState {
    var currentView: ViewMode = .todos
    var showSettings: Bool = false
    var showSidebar: Bool = false
    var showDoneList: Bool = false
    var showTrashList: Bool = false
    var pendingNavigationID: UUID? = nil
    var forwardTargetTodoID: UUID? = nil
    var activeProjectID: UUID? = nil
    /// Set to true from the top nav bar's actions menu to ask
    /// `ProjectDetailView` to expand its inline new-team form. The
    /// detail view binds its `showNewTeamInProject` flag to this so the
    /// nav bar can drive a piece of UI it doesn't render itself.
    var showNewTeamForActiveProject: Bool = false
    /// Drives the New Project sheet. Lifted out of `ProjectListView`
    /// so the top nav bar can present the sheet from its right-side
    /// "+ New Project" affordance — and so the sheet keeps working
    /// regardless of which sub-view of `ProjectsView` is mounted.
    var showNewProjectSheet: Bool = false
    /// Which `DispatchRun`'s brief-editor modal is open. Non-nil = sheet
    /// presented, nil = dismissed. Set by the "New Dispatch" / "Edit"
    /// buttons in ProjectDispatchSection, which create the run in `drafted`
    /// state first and then stash its id here.
    var dispatchModalRunID: UUID? = nil
    /// Which `EternalRun`'s brief-editor modal is open. Same pattern as
    /// `dispatchModalRunID`.
    var eternalModalRunID: UUID? = nil

    /// Which tile on the canvas holds the "keyboard selection" ring.
    /// Independent of AppKit's first responder — a tile can be SELECTED
    /// (arrow keys move between selected tiles) without being IN EDIT MODE
    /// (terminal owns keyDown). Edit mode is entered by clicking into a
    /// tile; exited via Escape or a click on the canvas background. When
    /// no tile is selected, arrow keys pick the nearest tile in the arrow
    /// direction.
    var focusedTileTodoID: UUID? = nil

    /// Which `EternalRun`'s Intervene sheet is presented. Non-nil while the
    /// user is composing a directive to that specific run's worker; nil
    /// when dismissed. Same presentation pattern as `eternalModalRunID`.
    /// Carries a run id (not a project id) so when multiple concurrent
    /// runs exist, the modal can't misclick onto the wrong worker's inbox.
    var eternalInterveneRunID: UUID? = nil
}
