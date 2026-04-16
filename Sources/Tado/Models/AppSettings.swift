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
    var claudeModelRaw: String = ClaudeModel.opus46.rawValue
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
    var randomTileColor: Bool = true

    init() {
        self.id = UUID()
        self.engineRaw = TerminalEngine.claude.rawValue
        self.gridColumns = 3
        self.claudeModeRaw = ClaudeMode.askPermissions.rawValue
        self.codexModeRaw = CodexMode.defaultPermissions.rawValue
        self.claudeEffortRaw = ClaudeEffort.high.rawValue
        self.codexEffortRaw = CodexEffort.high.rawValue
        self.claudeModelRaw = ClaudeModel.opus46.rawValue
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
        get { ClaudeModel(rawValue: claudeModelRaw) ?? .opus46 }
        set { claudeModelRaw = newValue.rawValue }
    }

    var codexModel: CodexModel {
        get { CodexModel(rawValue: codexModelRaw) ?? .gpt54 }
        set { codexModelRaw = newValue.rawValue }
    }
}
