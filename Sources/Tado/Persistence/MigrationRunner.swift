import Foundation
import SwiftData

/// Applies pending migrations on app launch. Reads the last-applied
/// id from `<root>/version`, applies every registered migration with
/// id > stored, bumps the marker after each success.
///
/// Called once from `TadoApp.init()` (after the ModelContainer is up).
enum MigrationRunner {
    /// All registered migrations, ordered by id.
    /// Add new migrations to the end of this list — never reorder.
    static let all: [Migration] = [
        Migration001_CreateGlobalJSON(),
        Migration002_CreateProjectJSON()
    ]

    @MainActor
    static func run(context: ModelContext) {
        let applied = readApplied()
        let pending = all.filter { $0.id > applied }
        guard !pending.isEmpty else { return }

        // Snapshot the app-support tree before the first migration
        // fires. If any migration corrupts state, the user can
        // untar `backups/tado-backup-<ts>-pre-migration.tar.gz`
        // back into place and relaunch.
        BackupManager.createBackup(reason: "pre-migration")

        for migration in pending {
            do {
                try migration.apply(context: context)
                writeApplied(migration.id)
                NSLog("[Migration] applied \(migration.id): \(migration.name)")
                EventBus.shared.publish(.systemMigrationRan(id: migration.id, name: migration.name))
            } catch {
                NSLog("[Migration] FAILED \(migration.id) \(migration.name): \(error)")
                return
            }
        }
    }

    private static func readApplied() -> Int {
        guard let data = AtomicStore.readIfExists(StorePaths.versionFile),
              let str = String(data: data, encoding: .utf8),
              let n = Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return n
    }

    private static func writeApplied(_ id: Int) {
        let data = "\(id)\n".data(using: .utf8) ?? Data()
        try? AtomicStore.write(data, to: StorePaths.versionFile)
    }
}
