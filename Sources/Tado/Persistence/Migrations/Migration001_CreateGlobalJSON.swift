import Foundation
import SwiftData

/// Migration 001: bootstrap `~/Library/Application Support/Tado/settings/global.json`
/// from the current SwiftData `AppSettings` row (if any), otherwise
/// from built-in defaults.
///
/// This is the one-time transition from "SwiftData-canonical" to
/// "files-canonical". Post-migration, `global.json` is the source
/// of truth; `AppSettings` becomes a cache kept in sync by
/// `AppSettingsSync`.
///
/// Idempotent: if `global.json` already exists and has a
/// `schemaVersion`, this migration is a no-op. Safe to re-run.
struct Migration001_CreateGlobalJSON: Migration {
    let id = 1
    let name = "create global.json from SwiftData AppSettings"

    func apply(context: ModelContext) throws {
        if FileManager.default.fileExists(atPath: StorePaths.globalSettingsFile.path) {
            return
        }

        var settings = GlobalSettings()
        settings.writer = "migration-001"
        settings.updatedAt = Date()

        let descriptor = FetchDescriptor<AppSettings>()
        if let row = try? context.fetch(descriptor).first {
            settings.ui.defaultThemeId = row.defaultThemeId
            settings.ui.randomTileColor = row.randomTileColor
            settings.ui.terminalFontSize = row.terminalFontSize
            settings.ui.terminalFontFamily = row.terminalFontFamily
            settings.ui.cursorBlink = row.cursorBlink
            settings.ui.bellMode = row.bellMode.rawValue

            settings.engine.default = row.engine.rawValue
            settings.engine.claude.mode = row.claudeMode.rawValue
            settings.engine.claude.effort = row.claudeEffort.rawValue
            settings.engine.claude.model = row.claudeModel.rawValue
            settings.engine.claude.noFlicker = row.claudeNoFlicker
            settings.engine.claude.mouseEnabled = row.claudeMouseEnabled
            settings.engine.claude.scrollSpeed = row.claudeScrollSpeed
            settings.engine.codex.mode = row.codexMode.rawValue
            settings.engine.codex.effort = row.codexEffort.rawValue
            settings.engine.codex.model = row.codexModel.rawValue
            settings.engine.codex.alternateScreen = row.codexAlternateScreen

            settings.canvas.gridColumns = row.gridColumns
        }

        try AtomicStore.encode(settings, to: StorePaths.globalSettingsFile)
    }
}
