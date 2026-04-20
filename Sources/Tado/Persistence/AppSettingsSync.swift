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
        if row.claudeModelRaw     != s.engine.claude.model     { row.claudeModelRaw = s.engine.claude.model }
        if row.claudeNoFlicker    != s.engine.claude.noFlicker { row.claudeNoFlicker = s.engine.claude.noFlicker }
        if row.claudeMouseEnabled != s.engine.claude.mouseEnabled { row.claudeMouseEnabled = s.engine.claude.mouseEnabled }
        if row.claudeScrollSpeed  != s.engine.claude.scrollSpeed  { row.claudeScrollSpeed = s.engine.claude.scrollSpeed }
        if row.codexModeRaw       != s.engine.codex.mode          { row.codexModeRaw = s.engine.codex.mode }
        if row.codexEffortRaw     != s.engine.codex.effort        { row.codexEffortRaw = s.engine.codex.effort }
        if row.codexModelRaw      != s.engine.codex.model         { row.codexModelRaw = s.engine.codex.model }
        if row.codexAlternateScreen != s.engine.codex.alternateScreen { row.codexAlternateScreen = s.engine.codex.alternateScreen }

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
        next.engine.claude.model     = row.claudeModelRaw
        next.engine.claude.noFlicker = row.claudeNoFlicker
        next.engine.claude.mouseEnabled = row.claudeMouseEnabled
        next.engine.claude.scrollSpeed  = row.claudeScrollSpeed
        next.engine.codex.mode          = row.codexModeRaw
        next.engine.codex.effort        = row.codexEffortRaw
        next.engine.codex.model         = row.codexModelRaw
        next.engine.codex.alternateScreen = row.codexAlternateScreen

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
