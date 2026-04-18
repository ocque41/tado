import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID
    var engineRaw: String
    var gridColumns: Int
    var claudeModeRaw: String = ClaudeMode.askPermissions.rawValue
    var codexModeRaw: String = CodexMode.defaultPermissions.rawValue
    var claudeEffortRaw: String = ClaudeEffort.high.rawValue
    var codexEffortRaw: String = CodexEffort.high.rawValue
    var claudeModelRaw: String = ClaudeModel.opus47.rawValue
    var codexModelRaw: String = CodexModel.gpt54.rawValue

    // Display / harness UI — defaults match Boris Cherny's "no flicker + all useful UI"
    // recommendation (CLAUDE_CODE_NO_FLICKER=1, mouse on, scroll speed = vim default).
    // See https://code.claude.com/docs/en/fullscreen
    var claudeNoFlicker: Bool = true
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

    // Per-phase timeout for the dispatch chain watchdog. If a phase
    // doesn't advance (its JSON `status` doesn't flip to "completed",
    // AND no later phase's JSON appears) within this budget, the
    // watchdog marks the project `stalled` and surfaces a Resume
    // button. Default 20 min gives phases doing real work
    // (build + tests + commit) comfortable headroom without letting
    // a wedged chain sit for hours.
    var dispatchPhaseTimeoutMinutes: Int = 20

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
        self.claudeEffortRaw = ClaudeEffort.high.rawValue
        self.codexEffortRaw = CodexEffort.high.rawValue
        self.claudeModelRaw = ClaudeModel.opus47.rawValue
        self.codexModelRaw = CodexModel.gpt54.rawValue
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
        get { ClaudeEffort(rawValue: claudeEffortRaw) ?? .high }
        set { claudeEffortRaw = newValue.rawValue }
    }

    var codexEffort: CodexEffort {
        get { CodexEffort(rawValue: codexEffortRaw) ?? .high }
        set { codexEffortRaw = newValue.rawValue }
    }

    var claudeModel: ClaudeModel {
        get { ClaudeModel(rawValue: claudeModelRaw) ?? .opus47 }
        set { claudeModelRaw = newValue.rawValue }
    }

    var codexModel: CodexModel {
        get { CodexModel(rawValue: codexModelRaw) ?? .gpt54 }
        set { codexModelRaw = newValue.rawValue }
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
