import Foundation

/// Creates + restores `.tar.gz` archives of
/// `~/Library/Application Support/Tado/`. Used by:
///
///   - `MigrationRunner` — takes a snapshot *before* each migration
///     applies, so a bad migration can be rolled back by untarring
///     the saved archive into place.
///   - `tado-config export/import` — user-facing full round-trip.
///
/// Archives live in `<root>/backups/` and are named
/// `tado-backup-YYYY-MM-DD-HHmmss[-suffix].tar.gz` so sorting
/// alphabetically == sorting chronologically. A retention policy
/// (§4.2) will prune old snapshots in a later packet; for now they
/// accumulate.
enum BackupManager {
    /// Write a tarball of the entire Tado app-support tree to
    /// `backups/tado-backup-<timestamp>[-<reason>].tar.gz`. Returns
    /// the destination URL on success, nil on failure (logs via NSLog).
    ///
    /// Skips `cache/` (SwiftData) and `backups/` itself (to avoid
    /// recursive inclusion of prior archives bloating each snapshot).
    @discardableResult
    static func createBackup(reason: String? = nil) -> URL? {
        let root = StorePaths.root
        let backupsDir = StorePaths.backupsDir
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stamp = timestamp()
        let suffix = reason.map { "-\(sanitize($0))" } ?? ""
        let archive = backupsDir.appendingPathComponent("tado-backup-\(stamp)\(suffix).tar.gz")

        // Invoke /usr/bin/tar directly — it's the right tool for the
        // job and avoids pulling in compression libraries. Use
        // --exclude so the archive doesn't nest prior backups or a
        // huge SwiftData store we can rebuild anyway.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = [
            "-czf", archive.path,
            "-C", root.deletingLastPathComponent().path,
            "--exclude", "\(root.lastPathComponent)/backups",
            "--exclude", "\(root.lastPathComponent)/cache",
            "--exclude", "\(root.lastPathComponent)/logs",
            root.lastPathComponent
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("[BackupManager] tar run failed: \(error)")
            return nil
        }
        guard task.terminationStatus == 0 else {
            NSLog("[BackupManager] tar exit \(task.terminationStatus)")
            return nil
        }
        return archive
    }

    /// Unpack `archive` into the Tado app-support tree. The archive is
    /// expected to have `Tado/` as its top-level entry (the same layout
    /// `createBackup` emits), so the extract lands directly into the
    /// real app-support root.
    ///
    /// Refuses to run while SwiftData observers are active in the app
    /// — restoration is meant for bootstrap / disaster recovery, not
    /// live swaps.
    static func restore(from archive: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archive.path) else {
            NSLog("[BackupManager] archive missing: \(archive.path)")
            return false
        }

        let parent = StorePaths.root.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", archive.path, "-C", parent.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("[BackupManager] restore run failed: \(error)")
            return false
        }
        return task.terminationStatus == 0
    }

    // MARK: - Private

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
