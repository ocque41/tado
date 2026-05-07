import SwiftUI

enum ViewMode: String, CaseIterable, Equatable {
    /// The "go home" landing page reached via the Tado wordmark in the
    /// top-left of the nav bar. Renders the live status dashboard
    /// (running agents, queued prompts, aggregate token / cost stats).
    /// Deliberately listed first so `Ctrl+Tab` cycling treats it as
    /// the canonical home; the four contextual workspaces follow.
    /// Note: `TopNavBar` iterates an explicit list `[.canvas, .projects,
    /// .todos, .extensions]` for the four-cell strip — the wordmark is
    /// the affordance for `.details`, not a fifth cell.
    case details
    case canvas
    case projects
    case todos
    case extensions

    // Relay-redesign nav cases — added so the top-bar / rail can
    // surface the eleven slots the brief enumerates (Todos / Canvas /
    // Kanban / Projects / Teams / Sessions / Dispatch / Knowledge /
    // Eternal / Pets / Settings). The new cases either open the
    // existing extension window (Knowledge → Dome window, Pets →
    // Pets window) or fall back to a related core surface until a
    // dedicated page lands in subsequent redesign phases.
    case kanban
    case teams
    case sessions
    case dispatch
    case knowledge
    case eternal
    case pets
    case settings

    var label: String {
        switch self {
        case .details:    "Details"
        case .canvas:     "Canvas"
        case .projects:   "Projects"
        case .todos:      "Todos"
        case .extensions: "Extensions"
        case .kanban:     "Kanban"
        case .teams:      "Teams"
        case .sessions:   "Sessions"
        case .dispatch:   "Dispatch"
        case .knowledge:  "Knowledge"
        case .eternal:    "Eternal"
        case .pets:       "Pets"
        case .settings:   "Settings"
        }
    }

    var icon: String {
        switch self {
        case .details:    "chart.bar.doc.horizontal"
        case .canvas:     "square.grid.3x3"
        case .projects:   "folder"
        case .todos:      "checklist"
        case .extensions: "puzzlepiece.extension"
        case .kanban:     "rectangle.split.3x1"
        case .teams:      "person.3"
        case .sessions:   "list.bullet.rectangle"
        case .dispatch:   "arrow.triangle.branch"
        case .knowledge:  "books.vertical"
        case .eternal:    "infinity"
        case .pets:       "pawprint"
        case .settings:   "gearshape"
        }
    }
}

/// Relay nav mode toggle (developer-facing, persisted via AppStorage
/// `relay.navMode`). `topbar` (default) is the 56px horizontal nav;
/// `rail` is the 64px vertical alternate. Read inside ContentView
/// via `@AppStorage("relay.navMode")` and switched via the
/// RelayTweaksPanel.
enum RelayNavMode: String, CaseIterable, Equatable {
    case topbar
    case rail
}

enum TerminalEngine: String, Codable, CaseIterable {
    case claude = "claude"
    case codex = "codex"
    /// Claude Cowork — the desktop-first knowledge-work coworker that
    /// ships inside the Claude Desktop app (`com.anthropic.claudefordesktop`).
    /// Unlike Claude Code and Codex, Cowork has NO standalone CLI binary.
    /// Tado launches it via the documented `claude://cowork/new?q=…&folder=…`
    /// URL scheme, shelled by the bundled `tado-cowork` Rust CLI. Output
    /// capture is one-way: Cowork writes its result markdown to
    /// `<project>/.tado/cowork/<run-id>.md` (a convention the bundled
    /// `tado-cowork-plugin` skill teaches Cowork to follow), and
    /// `CoworkOutputPoller` watches the file and renders it back into
    /// the tile. See the "Cowork engine + plugin" section of CLAUDE.md.
    case cowork = "cowork"

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cowork: "Claude Cowork"
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

    /// Per-mode fallback chain consulted by the spawn-fallback ladder
    /// (`TerminalManager.applySpawnFallback`). Ordered from "user's
    /// original choice" toward the most permissive still-functional
    /// alternative. The ladder steps through these on demonstrable
    /// CLI-rejection events; nil means "no further fallback —
    /// surface the failure to the user."
    func nextFallback() -> ClaudeMode? {
        switch self {
        case .autoMode:          return .bypassPermissions
        case .bypassPermissions: return .askPermissions
        case .planMode:          return .askPermissions
        case .askPermissions:    return nil
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

    /// Codex's analog of `ClaudeMode.nextFallback`. The picker has only
    /// three options, so the fallback chain is a single hop from
    /// `fullAccess` to the safer `defaultPermissions`. `custom` already
    /// emits no flags so it never triggers the ladder; `defaultPermissions`
    /// has nowhere safer to fall back to.
    func nextFallback() -> CodexMode? {
        switch self {
        case .fullAccess:         return .defaultPermissions
        case .defaultPermissions: return nil
        case .custom:             return nil
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

    /// Curated per-tile fallback chain when a model id is rejected by
    /// the live CLI (e.g. server pulled support for an old slug). Steps
    /// from largest/freshest toward smaller/older Claude variants the
    /// user's account is overwhelmingly likely to retain access to.
    /// Used by `TerminalManager.applySpawnFallback`.
    func nextFallback() -> ClaudeModel? {
        switch self {
        case .opus47_1M:   return .opus47
        case .opus47:      return .sonnet46_1M
        case .sonnet46_1M: return .sonnet46
        case .sonnet46:    return .haiku45
        case .haiku45:     return nil
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

    /// Curated per-tile fallback chain when Codex rejects a model id.
    /// Mirrors `ClaudeModel.nextFallback` shape. Stops at `gpt54Mini`
    /// (the smallest model the picker exposes); deeper fallback would
    /// either hop to Codex's pre-5 series or jump to Claude, both of
    /// which the ladder driver decides about separately at the
    /// engine-step rung.
    func nextFallback() -> CodexModel? {
        switch self {
        case .gpt55:       return .gpt54
        case .gpt54:       return .gpt54Mini
        case .gpt54Mini:   return nil
        case .gpt53Codex:  return .gpt54Mini
        case .gpt52:       return nil
        }
    }
}

/// Cowork's "mode" picker. Cowork has no CLI flags — it runs as a tab
/// inside the Claude Desktop app — so these modes don't translate to a
/// command-line argument. Instead, `tado-cowork` encodes the mode into
/// the prompt preamble it sends through `claude://cowork/new?q=…` so
/// Cowork's own intent classifier picks the right run shape.
///
/// `asyncTask` (default): the user describes an outcome and Cowork goes
/// off to work on it. Tado's tile waits for the result file at
/// `<project>/.tado/cowork/<run-id>.md` (the round-trip convention the
/// bundled `tado-cowork-plugin` skill teaches Cowork to follow).
/// `interactive`: the user wants to converse with Cowork directly from
/// the Desktop app — Tado fires the URL, opens the app, and the tile
/// shows a one-shot status line ("Cowork session opened in Claude
/// Desktop") with no output round-trip.
enum CoworkMode: String, Codable, CaseIterable {
    case asyncTask
    case interactive

    var displayName: String {
        switch self {
        case .asyncTask: "Async task (write result file)"
        case .interactive: "Interactive (use Desktop app)"
        }
    }
}

/// Cowork's effort/depth picker. Translated into prompt preamble hints
/// rather than CLI flags (Cowork has no `--effort` flag — it picks the
/// depth based on its own internal heuristics + your Desktop app
/// account tier). `auto` is the default and means "let Cowork decide."
enum CoworkEffort: String, Codable, CaseIterable {
    case auto
    case standard
    case extended

    var displayName: String {
        switch self {
        case .auto: "Auto (let Cowork pick)"
        case .standard: "Standard"
        case .extended: "Extended"
        }
    }
}

/// Cowork's model picker. Cowork picks the model from its own Desktop
/// app settings — Tado's selection here is a *hint* the bundled plugin's
/// preamble surfaces to Cowork ("the user prefers …"). It does NOT
/// override the Desktop app's configured model.
///
/// As of Claude Desktop v1.6259 Cowork supports the same Sonnet/Opus
/// family as Claude Code. The list intentionally trails Claude Code's
/// by one tick because Cowork availability for the freshest model can
/// lag by ~1 release.
enum CoworkModel: String, Codable, CaseIterable {
    case auto
    case opus47 = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"

    var displayName: String {
        switch self {
        case .auto: "Auto (Desktop app default)"
        case .opus47: "Opus 4.7 (hint)"
        case .sonnet46: "Sonnet 4.6 (hint)"
        }
    }

    static func normalizedRawValue(_ raw: String) -> String {
        switch raw {
        case "auto": return CoworkModel.auto.rawValue
        case "opus47": return CoworkModel.opus47.rawValue
        case "sonnet46": return CoworkModel.sonnet46.rawValue
        default:
            return CoworkModel(rawValue: raw)?.rawValue ?? CoworkModel.auto.rawValue
        }
    }
}

@Observable
@MainActor
final class AppState {
    var currentView: ViewMode = .todos
    var showSettings: Bool = false
    var showSidebar: Bool = false
    var showTadoUse: Bool = false
    var showDoneList: Bool = false
    var showTrashList: Bool = false
    var pendingNavigationID: UUID? = nil
    var forwardTargetTodoID: UUID? = nil
    /// Persisted across launches via `UserDefaults` so the "fresh launch
    /// feel" after macOS terminates the suspended app doesn't also lose
    /// the user's project context. Other in-memory UI flags (forwarding,
    /// modals, sheets) stay transient — those are one-shot intents that
    /// should not survive a relaunch.
    var activeProjectID: UUID? = AppState.loadPersistedActiveProjectID() {
        didSet {
            if let id = activeProjectID {
                UserDefaults.standard.set(id.uuidString, forKey: AppState.activeProjectIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppState.activeProjectIDKey)
            }
        }
    }
    private static let activeProjectIDKey = "tado.activeProjectID"
    private static func loadPersistedActiveProjectID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: activeProjectIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }
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

    /// Which body the Projects detail page renders for the active
    /// project. `detail` is today's behavior; `kanban` swaps the body
    /// for `ProjectKanbanView`. Stored on AppState so the toggle
    /// applies globally — switching projects keeps the user on whichever
    /// view they last picked, which matches how every other view-mode
    /// flag in this struct works (no per-project memory).
    var projectPageMode: ProjectPageMode = .detail

    /// Which grouping axis the per-project Kanban view uses to split
    /// cards into lanes. `.column` is today's user-managed columns;
    /// the others slice the same card set dynamically by the named
    /// dimension. Stored on AppState so the tab persists across
    /// project switches but is recomputed each launch — purely a UI
    /// affordance, no on-disk state.
    var kanbanGrouping: KanbanGroupingMode = .column
}

/// Discriminator for the shared `crafted.md` review modal. Keeps the
/// modal generic — it does not know the difference between an Eternal
/// worker plan and a Dispatch phase plan; it only knows which file path
/// to read and which Accept/Replan closures to invoke.
enum CraftedReviewKind: String, Codable {
    case dispatch
    case eternal
}

/// Per-project page-mode toggle on the Projects page. `detail` (default)
/// renders the existing `ProjectDetailView` with its Dispatch / Eternal
/// / Add Todo / Todos / Agents zones. `kanban` swaps the body for
/// `ProjectKanbanView` — a per-project board of user-managed columns
/// with todos as cards. The toggle lives on `AppState` (not on
/// `Project`) so it doesn't get persisted to disk; it's a UI affordance,
/// not durable state. Matches how `ViewMode` is structured.
enum ProjectPageMode: String, CaseIterable, Equatable {
    case detail
    case kanban

    var label: String {
        switch self {
        case .detail: "Detail"
        case .kanban: "Kanban"
        }
    }
}

/// Tabs at the top of the per-project Kanban board. Each axis renders
/// the same card set (todos + dispatch runs + eternal runs scoped to
/// the active project) into a different set of lanes:
///
/// - `.column` — user-managed `KanbanColumn` rows (`kind == "project"`).
///   The historical default; cards live in lanes the user named
///   (Backlog / Doing / Done by default, plus anything they added).
/// - `.status` — lanes by FSM state: Pending / Running / Awaiting /
///   Completed / Failed. Read-only grouping (you can't drag a card
///   from Pending to Running — the agent's actual state drives the
///   bucket).
/// - `.agent` — one lane per `agentName`, plus an "Unassigned" lane.
/// - `.team` — one lane per team in the project, plus "No team".
/// - `.kind` — Todo / Dispatch / Eternal — useful for spotting
///   long-running infrastructure runs alongside one-off todos.
enum KanbanGroupingMode: String, CaseIterable, Equatable {
    case column
    case status
    case agent
    case team
    case kind

    var label: String {
        switch self {
        case .column: "Columns"
        case .status: "Status"
        case .agent:  "Agents"
        case .team:   "Teams"
        case .kind:   "Kinds"
        }
    }

    var icon: String {
        switch self {
        case .column: "rectangle.split.3x1"
        case .status: "circle.dotted.and.circle"
        case .agent:  "person.crop.rectangle"
        case .team:   "person.3"
        case .kind:   "square.stack.3d.up"
        }
    }
}
