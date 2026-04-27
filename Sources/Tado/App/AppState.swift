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

/// Mirrors Claude Code's Effort picker (Shift+⌘+E). Source of truth for
/// what the CLI accepts:
///
///     $ claude --help | grep -- --effort
///     --effort <level>   Effort level for the current session
///                        (low, medium, high, xhigh, max)
///
/// The CLI accepts every level for every model. Per-model clamping
/// happens server-side and is opaque from outside Claude Code — Tado
/// has no introspection API for "what's the cap for Sonnet 4.6?" The
/// interactive `/model` picker bakes those caps into Claude Code's
/// binary; we cannot pull them as a source of truth from here.
///
/// To avoid silently coercing the user into model+effort combinations
/// they didn't intend (e.g. Sonnet + Max, where the server's clamp may
/// or may not match the user's mental model), `auto` is the default
/// and means "do not pass `--effort` at all" — Claude Code then picks
/// its own model-appropriate default. Users who want explicit control
/// can still pick a tier; the picker UI labels `auto` as the sane
/// default and flags `xhigh` / `max` as model-dependent.
enum ClaudeEffort: String, Codable, CaseIterable {
    case auto
    case low
    case medium
    case high
    case extraHigh = "xhigh"
    case max

    var displayName: String {
        switch self {
        case .auto: "Auto (let Claude Code pick)"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra high (model-dependent)"
        case .max: "Max (model-dependent)"
        }
    }

    /// `auto` returns `[]` — no flag is passed and Claude Code picks
    /// the right default for the chosen model. Every other case passes
    /// `--effort <raw>` verbatim; the server clamps to what the model
    /// actually supports.
    var cliFlags: [String] {
        switch self {
        case .auto: return []
        default: return ["--effort", rawValue]
        }
    }
}

enum CodexEffort: String, Codable, CaseIterable {
    case auto
    case low
    case medium
    case high
    case xhigh

    var displayName: String {
        switch self {
        case .auto: "Auto (let Codex pick)"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        }
    }

    var cliFlags: [String] {
        switch self {
        case .auto: return []
        default: return ["-c", "model_reasoning_effort=\"\(rawValue)\""]
        }
    }
}

/// Mirrors Claude Code's Model picker (Shift+⌘+I). Order matches the
/// in-app menu: Opus 4.7 → Opus 4.7 1M → Sonnet 4.6 → Sonnet 4.6 1M →
/// Haiku 4.5.
///
/// 1M variants use the CLI's bracket form (`opus[1m]`, `sonnet[1m]`).
/// Verified on v2.1.101 against the live API for `opus[1m]` (a
/// budget-capped `claude -p "..."` spawn routes to the model and
/// returns a response). The hyphenated `claude-*-1m` form is NOT
/// accepted ("model not found"), so the raw value uses the bracket
/// form. Shell-quoting is handled by the spawn path: `ProcessSpawner`
/// shell-escapes every flag token, so `[` and `]` survive zsh's
/// `nomatch` glob expansion.
enum ClaudeModel: String, Codable, CaseIterable {
    case opus47 = "claude-opus-4-7"
    case opus47_1M = "opus[1m]"
    case sonnet46 = "claude-sonnet-4-6"
    case sonnet46_1M = "sonnet[1m]"
    case haiku45 = "claude-haiku-4-5"

    var displayName: String {
        switch self {
        case .opus47: "Opus 4.7"
        case .opus47_1M: "Opus 4.7 1M"
        case .sonnet46: "Sonnet 4.6"
        case .sonnet46_1M: "Sonnet 4.6 1M"
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
        case "sonnet46_1M": return ClaudeModel.sonnet46_1M.rawValue
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

    /// Which run's `crafted.md` review modal is presented. Non-nil while
    /// the user is reading the architect's plan with the option to
    /// Accept (launch worker / phase 1) or Re-plan (re-spawn architect).
    /// Paired with `craftedReviewKind` so the same modal serves both
    /// Dispatch and Eternal — the kind disambiguates which run model and
    /// which service to load.
    var craftedReviewRunID: UUID? = nil
    var craftedReviewKind: CraftedReviewKind? = nil
}

/// Discriminator for the shared `crafted.md` review modal. Keeps the
/// modal generic — it does not know the difference between an Eternal
/// worker plan and a Dispatch phase plan; it only knows which file path
/// to read and which Accept/Replan closures to invoke.
enum CraftedReviewKind: String, Codable {
    case dispatch
    case eternal
}
