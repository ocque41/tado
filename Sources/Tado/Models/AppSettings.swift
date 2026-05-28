import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID
    var engineRaw: String
    var gridColumns: Int
    var claudeModeRaw: String = ClaudeMode.askPermissions.rawValue
    var codexModeRaw: String = CodexMode.defaultPermissions.rawValue
    var claudeEffortRaw: String = ClaudeEffort.auto.rawValue
    var codexEffortRaw: String = CodexEffort.auto.rawValue
    var claudeModelRaw: String = ClaudeModel.opus47.rawValue
    var codexModelRaw: String = CodexModel.gpt55.rawValue
    var coworkModeRaw: String = CoworkMode.asyncTask.rawValue
    var coworkEffortRaw: String = CoworkEffort.auto.rawValue
    var coworkModelRaw: String = CoworkModel.auto.rawValue

    // Advisor mode spawns two normal todo tiles: an executioner that only
    // executes short directed steps, and an advisor that decides the next step.
    // It is off by default and limited to CLI engines with PTY/tool support.
    var advisorEnabled: Bool = false
    var advisorDefaultsInitialized: Bool = false
    var advisorExecutionerEngineRaw: String = AdvisorRoleEngine.claude.rawValue
    var advisorExecutionerClaudeModeRaw: String = ClaudeMode.askPermissions.rawValue
    var advisorExecutionerClaudeModelRaw: String = ClaudeModel.sonnet46.rawValue
    var advisorExecutionerClaudeEffortRaw: String = ClaudeEffort.auto.rawValue
    var advisorExecutionerCodexModeRaw: String = CodexMode.defaultPermissions.rawValue
    var advisorExecutionerCodexModelRaw: String = CodexModel.gpt54.rawValue
    var advisorExecutionerCodexEffortRaw: String = CodexEffort.auto.rawValue
    var advisorAdvisorEngineRaw: String = AdvisorRoleEngine.claude.rawValue
    var advisorAdvisorClaudeModeRaw: String = ClaudeMode.askPermissions.rawValue
    var advisorAdvisorClaudeModelRaw: String = ClaudeModel.opus47.rawValue
    var advisorAdvisorClaudeEffortRaw: String = ClaudeEffort.high.rawValue
    var advisorAdvisorCodexModeRaw: String = CodexMode.defaultPermissions.rawValue
    var advisorAdvisorCodexModelRaw: String = CodexModel.gpt55.rawValue
    var advisorAdvisorCodexEffortRaw: String = CodexEffort.high.rawValue

    // Display / harness UI. Off by default because the fullscreen ("no flicker")
    // UI runs in alt-screen mode — every frame Claude Code paints replaces the
    // previous one, so nothing lands in the tile's scrollback buffer and
    // scroll-up stays blank. Users who prefer Boris Cherny's full UI can flip
    // this on in Settings; see https://code.claude.com/docs/en/fullscreen
    var claudeNoFlicker: Bool = false
    var claudeMouseEnabled: Bool = true
    var claudeScrollSpeed: Int = 3
    // Codex equivalent of CLAUDE_CODE_NO_FLICKER is `tui.alternate_screen`. Tado passes
    // `--no-alt-screen` for Codex by default because alt-screen breaks Codex command
    // execution in embedded SwiftTerm tiles. Flip this on if a future Codex release
    // makes alt-screen safe inside an embedded terminal.
    var codexAlternateScreen: Bool = false
    // When true, every new terminal tile picks a random theme from TerminalTheme.all.
    // Off by default so new installs land on the house theme (Ember) — flip
    // on from Settings for the per-tile rotation.
    var randomTileColor: Bool = false

    // Theme used when `randomTileColor` is off. String id so SwiftData
    // doesn't need a migration when the palette grows. Falls back to
    // `TerminalTheme.tadoDark` if the id isn't in the catalog.
    var defaultThemeId: String = "ember"

    // Vestigial SwiftData column from the Phase 2 rollout window. SwiftTerm
    // has been removed; the Metal renderer is now the only code path. Kept
    // as a stored property so SwiftData migrations don't have to drop the
    // column — the value is ignored by all call sites. A later migration
    // can formally remove it.
    var useMetalRenderer: Bool = true

    // Monospace point size used by the Metal renderer. Changes take effect
    // for tiles spawned after the setting flips; existing tiles keep their
    // current metrics so scrollback geometry stays stable.
    var terminalFontSize: Int = 13

    // Family name of the monospace font used by the Metal renderer.
    // Empty string = system monospaced (SF Mono). Invalid / proportional
    // names fall back to the system font silently — see
    // `FontMetrics.font(named:size:scale:)`. Stored as a string so the
    // setting survives macOS font uninstalls without a schema migration.
    var terminalFontFamily: String = ""

    // Whether the Metal renderer blinks the cursor. Matches Terminal.app's
    // default. Honored live — toggling in Settings affects all tiles next
    // frame, since the blink timer lives in the view, not the renderer.
    var cursorBlink: Bool = true

    // One-shot migration flag: when false on launch, iterate all Projects
    // and set `eternalSkipPermissions = true`. This catches projects created
    // before the default flipped, so every existing project honors the
    // "dangerously-skip-permissions on by default" rule after a single
    // launch. Users who later flip the toggle OFF explicitly are not re-
    // migrated — the flag stays true forever.
    var didMigrateEternalDefaults: Bool = false

    // One-shot migration flag for the multi-run upgrade. When false on
    // launch, iterate all Projects and:
    //   1. For any project with non-idle `eternalState` OR a legacy
    //      `.tado/eternal/{state.json,crafted.md,…}` on disk, create one
    //      `EternalRun` row and MOVE the legacy files under
    //      `.tado/eternal/runs/<run-uuid>/`.
    //   2. Same for Dispatch → `DispatchRun` + `.tado/dispatch/runs/<id>/`.
    // Running workers can't hot-migrate (bash wrappers reference the old
    // paths in memory), so any `eternalState == "running"` demotes to
    // `stopped` after the move — the user restarts manually.
    // Once set to true, the migration never runs again; callers rely on
    // the flag for idempotence.
    var didMigrateToMultipleRuns: Bool = false

    // Phase 4: per-user kill switch for code-index file watching.
    // Defaults true so the auto-watch path the NewProjectSheet sets up
    // actually does its job. Toggling off in Settings stops every
    // active watcher and prevents future ones from starting; flipping
    // back on calls `code.watch.resume_all` to reattach. Indexed
    // chunks already on disk stay queryable via `dome_code_search`
    // either way.
    var codeIndexingEnabled: Bool = true

    // How terminal bells (0x07) are surfaced on the Metal path. Stored
    // as a raw string so SwiftData schema stays stable if we add modes
    // later. Default matches Terminal.app: audible-only.
    var bellModeRaw: String = BellMode.audible.rawValue
    var bellMode: BellMode {
        get { BellMode(rawValue: bellModeRaw) ?? .audible }
        set { bellModeRaw = newValue.rawValue }
    }

    init() {
        self.id = UUID()
        self.engineRaw = TerminalEngine.claude.rawValue
        self.gridColumns = 3
        self.claudeModeRaw = ClaudeMode.askPermissions.rawValue
        self.codexModeRaw = CodexMode.defaultPermissions.rawValue
        self.claudeEffortRaw = ClaudeEffort.auto.rawValue
        self.codexEffortRaw = CodexEffort.auto.rawValue
        self.claudeModelRaw = ClaudeModel.opus47.rawValue
        self.codexModelRaw = CodexModel.gpt55.rawValue
        self.coworkModeRaw = CoworkMode.asyncTask.rawValue
        self.coworkEffortRaw = CoworkEffort.auto.rawValue
        self.coworkModelRaw = CoworkModel.auto.rawValue
    }

    var engine: TerminalEngine {
        get { TerminalEngine(rawValue: engineRaw) ?? .claude }
        set { engineRaw = newValue.rawValue }
    }

    var claudeMode: ClaudeMode {
        get { ClaudeMode(rawValue: claudeModeRaw) ?? .askPermissions }
        set { claudeModeRaw = newValue.rawValue }
    }

    var codexMode: CodexMode {
        get { CodexMode(rawValue: codexModeRaw) ?? .defaultPermissions }
        set { codexModeRaw = newValue.rawValue }
    }

    var claudeEffort: ClaudeEffort {
        get { ClaudeEffort(rawValue: claudeEffortRaw) ?? .auto }
        set { claudeEffortRaw = newValue.rawValue }
    }

    var codexEffort: CodexEffort {
        get { CodexEffort(rawValue: codexEffortRaw) ?? .auto }
        set { codexEffortRaw = newValue.rawValue }
    }

    var claudeModel: ClaudeModel {
        get { ClaudeModel(rawValue: ClaudeModel.normalizedRawValue(claudeModelRaw)) ?? .opus47 }
        set { claudeModelRaw = newValue.rawValue }
    }

    var codexModel: CodexModel {
        get { CodexModel(rawValue: CodexModel.normalizedRawValue(codexModelRaw)) ?? .gpt55 }
        set { codexModelRaw = newValue.rawValue }
    }

    var coworkMode: CoworkMode {
        get { CoworkMode(rawValue: coworkModeRaw) ?? .asyncTask }
        set { coworkModeRaw = newValue.rawValue }
    }

    var coworkEffort: CoworkEffort {
        get { CoworkEffort(rawValue: coworkEffortRaw) ?? .auto }
        set { coworkEffortRaw = newValue.rawValue }
    }

    var coworkModel: CoworkModel {
        get { CoworkModel(rawValue: CoworkModel.normalizedRawValue(coworkModelRaw)) ?? .auto }
        set { coworkModelRaw = newValue.rawValue }
    }

    var advisorExecutionerEngine: AdvisorRoleEngine {
        get { AdvisorRoleEngine(rawValue: advisorExecutionerEngineRaw) ?? .claude }
        set { advisorExecutionerEngineRaw = newValue.rawValue }
    }

    var advisorAdvisorEngine: AdvisorRoleEngine {
        get { AdvisorRoleEngine(rawValue: advisorAdvisorEngineRaw) ?? .claude }
        set { advisorAdvisorEngineRaw = newValue.rawValue }
    }

    var advisorExecutionerClaudeMode: ClaudeMode {
        get { ClaudeMode(rawValue: advisorExecutionerClaudeModeRaw) ?? .askPermissions }
        set { advisorExecutionerClaudeModeRaw = newValue.rawValue }
    }

    var advisorExecutionerClaudeModel: ClaudeModel {
        get { ClaudeModel(rawValue: ClaudeModel.normalizedRawValue(advisorExecutionerClaudeModelRaw)) ?? .sonnet46 }
        set { advisorExecutionerClaudeModelRaw = newValue.rawValue }
    }

    var advisorExecutionerClaudeEffort: ClaudeEffort {
        get { ClaudeEffort(rawValue: advisorExecutionerClaudeEffortRaw) ?? .auto }
        set { advisorExecutionerClaudeEffortRaw = newValue.rawValue }
    }

    var advisorExecutionerCodexMode: CodexMode {
        get { CodexMode(rawValue: advisorExecutionerCodexModeRaw) ?? .defaultPermissions }
        set { advisorExecutionerCodexModeRaw = newValue.rawValue }
    }

    var advisorExecutionerCodexModel: CodexModel {
        get { CodexModel(rawValue: CodexModel.normalizedRawValue(advisorExecutionerCodexModelRaw)) ?? .gpt54 }
        set { advisorExecutionerCodexModelRaw = newValue.rawValue }
    }

    var advisorExecutionerCodexEffort: CodexEffort {
        get { CodexEffort(rawValue: advisorExecutionerCodexEffortRaw) ?? .auto }
        set { advisorExecutionerCodexEffortRaw = newValue.rawValue }
    }

    var advisorAdvisorClaudeMode: ClaudeMode {
        get { ClaudeMode(rawValue: advisorAdvisorClaudeModeRaw) ?? .askPermissions }
        set { advisorAdvisorClaudeModeRaw = newValue.rawValue }
    }

    var advisorAdvisorClaudeModel: ClaudeModel {
        get { ClaudeModel(rawValue: ClaudeModel.normalizedRawValue(advisorAdvisorClaudeModelRaw)) ?? .opus47 }
        set { advisorAdvisorClaudeModelRaw = newValue.rawValue }
    }

    var advisorAdvisorClaudeEffort: ClaudeEffort {
        get { ClaudeEffort(rawValue: advisorAdvisorClaudeEffortRaw) ?? .high }
        set { advisorAdvisorClaudeEffortRaw = newValue.rawValue }
    }

    var advisorAdvisorCodexMode: CodexMode {
        get { CodexMode(rawValue: advisorAdvisorCodexModeRaw) ?? .defaultPermissions }
        set { advisorAdvisorCodexModeRaw = newValue.rawValue }
    }

    var advisorAdvisorCodexModel: CodexModel {
        get { CodexModel(rawValue: CodexModel.normalizedRawValue(advisorAdvisorCodexModelRaw)) ?? .gpt55 }
        set { advisorAdvisorCodexModelRaw = newValue.rawValue }
    }

    var advisorAdvisorCodexEffort: CodexEffort {
        get { CodexEffort(rawValue: advisorAdvisorCodexEffortRaw) ?? .high }
        set { advisorAdvisorCodexEffortRaw = newValue.rawValue }
    }

    func initializeAdvisorDefaultsIfNeeded() {
        guard !advisorDefaultsInitialized else { return }
        let copiedEngine = AdvisorRoleEngine(terminalEngine: engine)
        advisorExecutionerEngine = copiedEngine
        switch copiedEngine {
        case .claude:
            advisorExecutionerClaudeMode = claudeMode
            advisorExecutionerClaudeModel = claudeModel
            advisorExecutionerClaudeEffort = claudeEffort
        case .codex:
            advisorExecutionerCodexMode = codexMode
            advisorExecutionerCodexModel = codexModel
            advisorExecutionerCodexEffort = codexEffort
        }
        advisorAdvisorEngine = .claude
        advisorAdvisorClaudeMode = .askPermissions
        advisorAdvisorClaudeModel = .opus47
        advisorAdvisorClaudeEffort = .high
        advisorAdvisorCodexMode = .defaultPermissions
        advisorAdvisorCodexModel = .gpt55
        advisorAdvisorCodexEffort = .high
        advisorDefaultsInitialized = true
    }

    func advisorEngine(for role: AdvisorRole) -> TerminalEngine {
        switch role {
        case .executioner:
            return advisorExecutionerEngine.terminalEngine
        case .advisor:
            return advisorAdvisorEngine.terminalEngine
        }
    }

    func advisorModeFlags(for role: AdvisorRole) -> [String] {
        let engine = advisorEngine(for: role)
        switch (role, engine) {
        case (.executioner, .claude):
            return advisorExecutionerClaudeMode.cliFlags
        case (.advisor, .claude):
            return advisorAdvisorClaudeMode.cliFlags
        case (.executioner, .codex):
            return ProcessSpawner.codexEmbedShim(allowAlternateScreen: codexAlternateScreen)
                + advisorExecutionerCodexMode.cliFlags
        case (.advisor, .codex):
            return ProcessSpawner.codexEmbedShim(allowAlternateScreen: codexAlternateScreen)
                + advisorAdvisorCodexMode.cliFlags
        case (_, .cowork):
            return []
        }
    }

    func advisorModelFlags(for role: AdvisorRole) -> [String] {
        switch (role, advisorEngine(for: role)) {
        case (.executioner, .claude): return advisorExecutionerClaudeModel.cliFlags
        case (.advisor, .claude): return advisorAdvisorClaudeModel.cliFlags
        case (.executioner, .codex): return advisorExecutionerCodexModel.cliFlags
        case (.advisor, .codex): return advisorAdvisorCodexModel.cliFlags
        case (_, .cowork): return []
        }
    }

    func advisorEffortFlags(for role: AdvisorRole) -> [String] {
        switch (role, advisorEngine(for: role)) {
        case (.executioner, .claude): return advisorExecutionerClaudeEffort.cliFlags
        case (.advisor, .claude): return advisorAdvisorClaudeEffort.cliFlags
        case (.executioner, .codex): return advisorExecutionerCodexEffort.cliFlags
        case (.advisor, .codex): return advisorAdvisorCodexEffort.cliFlags
        case (_, .cowork): return []
        }
    }
}

/// How a terminal bell (0x07) is surfaced to the user. Mirrors the
/// options Terminal.app exposes. Honored by the Metal renderer's bell
/// drain each idle-tick.
enum BellMode: String, CaseIterable, Identifiable {
    case off
    case audible
    case visual
    case both

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:     return "Off"
        case .audible: return "Audible only (NSBeep)"
        case .visual:  return "Visual flash"
        case .both:    return "Audible + visual"
        }
    }
}
