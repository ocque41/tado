import Foundation
import SwiftData

/// Keeps the SwiftData `AppSettings` cache row synchronized with the
/// canonical `global.json`.
///
/// Direction of flow:
///   - **JSON → SwiftData**: on bootstrap, and on every `FileWatcher`
///     fire from `ScopedConfig`. Applies `GlobalSettings` values onto
///     the single `AppSettings` row (creating it if none exists).
///     SwiftUI `@Query` observers redraw automatically.
///   - **SwiftData → JSON**: after every `ModelContext.didSave`
///     notification, diff the current `AppSettings` row against the
///     in-memory `GlobalSettings`. If different, push the delta to
///     `ScopedConfig.setGlobal`.
///
/// The round-trip is de-duplicated by comparing values before writing
/// — JSON → SwiftData applies don't trigger SwiftData → JSON writes
/// because nothing changed vs the in-memory snapshot. And ScopedConfig
/// itself ignores watcher fires within 500ms of a self-write.
@MainActor
final class AppSettingsSync {
    private let container: ModelContainer
    private let context: ModelContext
    private var saveObserver: NSObjectProtocol?

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    func start() {
        // Ensure a row exists and is hydrated from JSON.
        applyJSONToSwiftData(ScopedConfig.shared.get())

        // JSON → SwiftData on external edits.
        ScopedConfig.shared.addOnChange { [weak self] scope in
            guard scope == .global, let self else { return }
            self.applyJSONToSwiftData(ScopedConfig.shared.get())
        }

        // SwiftData → JSON on any save.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushSwiftDataToJSON() }
        }
    }

    // MARK: - JSON → SwiftData

    private func applyJSONToSwiftData(_ s: GlobalSettings) {
        let row = fetchOrCreate()
        if row.defaultThemeId     != s.ui.defaultThemeId     { row.defaultThemeId = s.ui.defaultThemeId }
        if row.randomTileColor    != s.ui.randomTileColor    { row.randomTileColor = s.ui.randomTileColor }
        if row.terminalFontSize   != s.ui.terminalFontSize   { row.terminalFontSize = s.ui.terminalFontSize }
        if row.terminalFontFamily != s.ui.terminalFontFamily { row.terminalFontFamily = s.ui.terminalFontFamily }
        if row.cursorBlink        != s.ui.cursorBlink        { row.cursorBlink = s.ui.cursorBlink }
        if row.bellModeRaw        != s.ui.bellMode           { row.bellModeRaw = s.ui.bellMode }

        if row.engineRaw          != s.engine.default          { row.engineRaw = s.engine.default }
        if row.claudeModeRaw      != s.engine.claude.mode      { row.claudeModeRaw = s.engine.claude.mode }
        if row.claudeEffortRaw    != s.engine.claude.effort    { row.claudeEffortRaw = s.engine.claude.effort }
        let claudeModel = ClaudeModel.normalizedRawValue(s.engine.claude.model)
        if row.claudeModelRaw     != claudeModel               { row.claudeModelRaw = claudeModel }
        if row.claudeNoFlicker    != s.engine.claude.noFlicker { row.claudeNoFlicker = s.engine.claude.noFlicker }
        if row.claudeMouseEnabled != s.engine.claude.mouseEnabled { row.claudeMouseEnabled = s.engine.claude.mouseEnabled }
        if row.claudeScrollSpeed  != s.engine.claude.scrollSpeed  { row.claudeScrollSpeed = s.engine.claude.scrollSpeed }
        if row.codexModeRaw       != s.engine.codex.mode          { row.codexModeRaw = s.engine.codex.mode }
        if row.codexEffortRaw     != s.engine.codex.effort        { row.codexEffortRaw = s.engine.codex.effort }
        let codexModel = CodexModel.normalizedRawValue(s.engine.codex.model)
        if row.codexModelRaw      != codexModel                   { row.codexModelRaw = codexModel }
        if row.codexAlternateScreen != s.engine.codex.alternateScreen { row.codexAlternateScreen = s.engine.codex.alternateScreen }

        if row.advisorEnabled != s.engine.advisor.enabled { row.advisorEnabled = s.engine.advisor.enabled }
        if row.advisorDefaultsInitialized != s.engine.advisor.defaultsInitialized {
            row.advisorDefaultsInitialized = s.engine.advisor.defaultsInitialized
        }
        if row.advisorExecutionerEngineRaw != s.engine.advisor.executioner.engine {
            row.advisorExecutionerEngineRaw = s.engine.advisor.executioner.engine
        }
        if row.advisorExecutionerClaudeModeRaw != s.engine.advisor.executioner.claude.mode {
            row.advisorExecutionerClaudeModeRaw = s.engine.advisor.executioner.claude.mode
        }
        let execClaudeModel = ClaudeModel.normalizedRawValue(s.engine.advisor.executioner.claude.model)
        if row.advisorExecutionerClaudeModelRaw != execClaudeModel {
            row.advisorExecutionerClaudeModelRaw = execClaudeModel
        }
        if row.advisorExecutionerClaudeEffortRaw != s.engine.advisor.executioner.claude.effort {
            row.advisorExecutionerClaudeEffortRaw = s.engine.advisor.executioner.claude.effort
        }
        if row.advisorExecutionerCodexModeRaw != s.engine.advisor.executioner.codex.mode {
            row.advisorExecutionerCodexModeRaw = s.engine.advisor.executioner.codex.mode
        }
        let execCodexModel = CodexModel.normalizedRawValue(s.engine.advisor.executioner.codex.model)
        if row.advisorExecutionerCodexModelRaw != execCodexModel {
            row.advisorExecutionerCodexModelRaw = execCodexModel
        }
        if row.advisorExecutionerCodexEffortRaw != s.engine.advisor.executioner.codex.effort {
            row.advisorExecutionerCodexEffortRaw = s.engine.advisor.executioner.codex.effort
        }
        if row.advisorAdvisorEngineRaw != s.engine.advisor.advisor.engine {
            row.advisorAdvisorEngineRaw = s.engine.advisor.advisor.engine
        }
        if row.advisorAdvisorClaudeModeRaw != s.engine.advisor.advisor.claude.mode {
            row.advisorAdvisorClaudeModeRaw = s.engine.advisor.advisor.claude.mode
        }
        let advisorClaudeModel = ClaudeModel.normalizedRawValue(s.engine.advisor.advisor.claude.model)
        if row.advisorAdvisorClaudeModelRaw != advisorClaudeModel {
            row.advisorAdvisorClaudeModelRaw = advisorClaudeModel
        }
        if row.advisorAdvisorClaudeEffortRaw != s.engine.advisor.advisor.claude.effort {
            row.advisorAdvisorClaudeEffortRaw = s.engine.advisor.advisor.claude.effort
        }
        if row.advisorAdvisorCodexModeRaw != s.engine.advisor.advisor.codex.mode {
            row.advisorAdvisorCodexModeRaw = s.engine.advisor.advisor.codex.mode
        }
        let advisorCodexModel = CodexModel.normalizedRawValue(s.engine.advisor.advisor.codex.model)
        if row.advisorAdvisorCodexModelRaw != advisorCodexModel {
            row.advisorAdvisorCodexModelRaw = advisorCodexModel
        }
        if row.advisorAdvisorCodexEffortRaw != s.engine.advisor.advisor.codex.effort {
            row.advisorAdvisorCodexEffortRaw = s.engine.advisor.advisor.codex.effort
        }

        if row.gridColumns        != s.canvas.gridColumns { row.gridColumns = s.canvas.gridColumns }

        try? context.save()
    }

    private func fetchOrCreate() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first { return existing }
        let fresh = AppSettings()
        context.insert(fresh)
        try? context.save()
        return fresh
    }

    // MARK: - SwiftData → JSON

    private func pushSwiftDataToJSON() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let row = try? context.fetch(descriptor).first else { return }

        let current = ScopedConfig.shared.get()
        var next = current

        next.ui.defaultThemeId     = row.defaultThemeId
        next.ui.randomTileColor    = row.randomTileColor
        next.ui.terminalFontSize   = row.terminalFontSize
        next.ui.terminalFontFamily = row.terminalFontFamily
        next.ui.cursorBlink        = row.cursorBlink
        next.ui.bellMode           = row.bellModeRaw

        next.engine.default          = row.engineRaw
        next.engine.claude.mode      = row.claudeModeRaw
        next.engine.claude.effort    = row.claudeEffortRaw
        next.engine.claude.model     = row.claudeModel.rawValue
        next.engine.claude.noFlicker = row.claudeNoFlicker
        next.engine.claude.mouseEnabled = row.claudeMouseEnabled
        next.engine.claude.scrollSpeed  = row.claudeScrollSpeed
        next.engine.codex.mode          = row.codexModeRaw
        next.engine.codex.effort        = row.codexEffortRaw
        next.engine.codex.model         = row.codexModel.rawValue
        next.engine.codex.alternateScreen = row.codexAlternateScreen
        next.engine.advisor.enabled = row.advisorEnabled
        next.engine.advisor.defaultsInitialized = row.advisorDefaultsInitialized
        next.engine.advisor.executioner.engine = row.advisorExecutionerEngine.rawValue
        next.engine.advisor.executioner.claude.mode = row.advisorExecutionerClaudeModeRaw
        next.engine.advisor.executioner.claude.model = row.advisorExecutionerClaudeModel.rawValue
        next.engine.advisor.executioner.claude.effort = row.advisorExecutionerClaudeEffortRaw
        next.engine.advisor.executioner.codex.mode = row.advisorExecutionerCodexModeRaw
        next.engine.advisor.executioner.codex.model = row.advisorExecutionerCodexModel.rawValue
        next.engine.advisor.executioner.codex.effort = row.advisorExecutionerCodexEffortRaw
        next.engine.advisor.advisor.engine = row.advisorAdvisorEngine.rawValue
        next.engine.advisor.advisor.claude.mode = row.advisorAdvisorClaudeModeRaw
        next.engine.advisor.advisor.claude.model = row.advisorAdvisorClaudeModel.rawValue
        next.engine.advisor.advisor.claude.effort = row.advisorAdvisorClaudeEffortRaw
        next.engine.advisor.advisor.codex.mode = row.advisorAdvisorCodexModeRaw
        next.engine.advisor.advisor.codex.model = row.advisorAdvisorCodexModel.rawValue
        next.engine.advisor.advisor.codex.effort = row.advisorAdvisorCodexEffortRaw

        next.canvas.gridColumns = row.gridColumns

        // Skip write if nothing relevant changed. Cheap compare via
        // Equatable conformance on GlobalSettings (updatedAt/writer
        // differ intentionally in `current`, so compare by zeroing them).
        var a = current; a.writer = ""; a.updatedAt = .distantPast
        var b = next;    b.writer = ""; b.updatedAt = .distantPast
        guard a != b else { return }

        ScopedConfig.shared.setGlobal { $0 = next }
    }
}
