import SwiftUI

enum ViewMode: String, CaseIterable, Equatable {
    case canvas
    case projects
    case todos
    case extensions

    var label: String {
        switch self {
        case .canvas: "Canvas"
        case .projects: "Projects"
        case .todos: "Todos"
        case .extensions: "Extensions"
        }
    }

    var icon: String {
        switch self {
        case .canvas: "square.grid.3x3"
        case .projects: "folder"
        case .todos: "checklist"
        case .extensions: "puzzlepiece.extension"
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

/// Mirrors Claude Code's own Mode picker (Shift+⌘+M). Order matches the
/// in-app menu so Tado's picker reads the same top-to-bottom.
///
/// `autoAcceptEdits` was removed when Claude Code dropped it from the main
/// Mode menu in favor of `autoMode`, which is the new preferred long-
/// running default (AI-classifier-gated permission grants; see
/// `EternalService.mergeAutoModeKeys` for the settings.json side).
enum ClaudeMode: String, Codable, CaseIterable {
    case askPermissions
    case planMode
    case autoMode
    case bypassPermissions

    var displayName: String {
        switch self {
        case .askPermissions: "Ask permissions"
        case .planMode: "Plan mode"
        case .autoMode: "Auto mode"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    var cliFlags: [String] {
        switch self {
        case .askPermissions:    return ["--permission-mode", "default"]
        case .planMode:          return ["--permission-mode", "plan"]
        case .autoMode:          return ["--permission-mode", "auto"]
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

/// Mirrors Claude Code's Effort picker (Shift+⌘+E). Order matches the
/// in-app menu: Low → Medium → High → Extra high → Max.
///
/// Claude Code v2.1.114+ accepts `--effort xhigh` for the "Extra high"
/// tier. Older builds (verified rejection on v2.1.101) only accept
/// `low|medium|high|max`; on those, a spawn using Extra high errors out
/// with "option '--effort <level>' argument 'xhigh' is invalid" and the
/// user falls back to High or Max. The raw value is `xhigh` (not
/// `extra-high`) — that's the token the CLI parser expects.
enum ClaudeEffort: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case extraHigh = "xhigh"
    case max

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra high"
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

/// Mirrors Claude Code's Model picker (Shift+⌘+I). Order matches the
/// in-app menu: Opus 4.7 → Opus 4.7 1M → Sonnet 4.6 → Haiku 4.5.
///
/// Opus 4.7 1M is the 1M-context variant. The CLI accepts the bracket
/// form `--model "opus[1m]"` — verified on v2.1.101 against the live API
/// (a budget-capped `claude -p "..."` spawn routes to the model and
/// returns a response). The hyphenated `claude-opus-4-7-1m` form is
/// NOT accepted ("model not found"), so the enum raw value uses the
/// bracket form. Shell-quoting is handled by the spawn path:
/// `ProcessSpawner` passes `cliFlags` as an argv array, so `[` and `]`
/// never touch a shell that would glob them.
enum ClaudeModel: String, Codable, CaseIterable {
    case opus47 = "claude-opus-4-7"
    case opus47_1M = "opus[1m]"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45 = "claude-haiku-4-5"

    var displayName: String {
        switch self {
        case .opus47: "Opus 4.7"
        case .opus47_1M: "Opus 4.7 1M"
        case .sonnet46: "Sonnet 4.6"
        case .haiku45: "Haiku 4.5"
        }
    }

    var cliFlags: [String] {
        return ["--model", rawValue]
    }

    static func normalizedRawValue(_ raw: String) -> String {
        switch raw {
        case "opus47": return ClaudeModel.opus47.rawValue
        case "opus47_1M": return ClaudeModel.opus47_1M.rawValue
        case "sonnet46": return ClaudeModel.sonnet46.rawValue
        case "haiku45": return ClaudeModel.haiku45.rawValue
        default:
            return ClaudeModel(rawValue: raw)?.rawValue ?? ClaudeModel.opus47.rawValue
        }
    }
}

enum CodexModel: String, Codable, CaseIterable {
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt53Codex = "gpt-5.3-codex"
    case gpt52 = "gpt-5.2"

    var displayName: String {
        switch self {
        case .gpt55: "GPT-5.5"
        case .gpt54: "GPT-5.4"
        case .gpt54Mini: "GPT-5.4-Mini"
        case .gpt53Codex: "GPT-5.3-Codex"
        case .gpt52: "GPT-5.2"
        }
    }

    var cliFlags: [String] {
        return ["-c", "model=\"\(rawValue)\""]
    }

    static func normalizedRawValue(_ raw: String) -> String {
        switch raw {
        case "gpt55": return CodexModel.gpt55.rawValue
        case "gpt54": return CodexModel.gpt54.rawValue
        case "gpt54Mini": return CodexModel.gpt54Mini.rawValue
        case "gpt53Codex": return CodexModel.gpt53Codex.rawValue
        case "gpt52": return CodexModel.gpt52.rawValue
        case "gpt-5.1-codex-max",
             "gpt-5.1-codex",
             "gpt-5.1-codex-mini",
             "gpt-5.2-codex",
             "gpt52Codex",
             "gpt51CodexMax",
             "gpt51CodexMini":
            return CodexModel.gpt55.rawValue
        default:
            return CodexModel(rawValue: raw)?.rawValue ?? CodexModel.gpt55.rawValue
        }
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
