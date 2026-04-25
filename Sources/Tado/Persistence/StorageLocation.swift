import Foundation

struct StorageLocationRecord: Codable, Equatable {
    var schemaVersion: Int = 1
    var activeRoot: String?
    var pendingRoot: String?
    var lastMoveError: String?
    var updatedAt: Date = Date()
}

enum StorageLocationError: LocalizedError {
    case targetInsideCurrentStore
    case currentStoreInsideTarget
    case targetIsFile(URL)
    case targetContainsUnrelatedFiles(URL)
    case targetNotWritable(URL)
    case copyVerificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .targetInsideCurrentStore:
            return "The new storage folder cannot be inside the current Tado storage folder."
        case .currentStoreInsideTarget:
            return "The new storage folder cannot contain the current Tado storage folder."
        case .targetIsFile(let url):
            return "\(url.path) is a file, not a folder."
        case .targetContainsUnrelatedFiles(let url):
            return "\(url.path) is not empty and does not look like a Tado storage folder."
        case .targetNotWritable(let url):
            return "\(url.path) is not writable."
        case .copyVerificationFailed(let url):
            return "Tado copied the store, but verification failed at \(url.path)."
        }
    }
}

enum StorageLocationManager {
    static let locatorFileName = "storage-location.json"

    static var defaultRoot: URL {
        if let override = getenv("TADO_STORAGE_DEFAULT_ROOT"), let raw = String(validatingUTF8: override), !raw.isEmpty {
            let url = normalize(URL(fileURLWithPath: raw, isDirectory: true))
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = (base ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent(StorePaths.appName, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var locatorFile: URL {
        defaultRoot.appendingPathComponent(locatorFileName)
    }

    static var currentRoot: URL {
        let record = readRecord()
        let root = record.activeRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            .map(normalize)
            ?? defaultRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var pendingRoot: URL? {
        readRecord().pendingRoot.flatMap { $0.isEmpty ? nil : normalize(URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    static var lastMoveError: String? {
        readRecord().lastMoveError
    }

    static var isUsingDefaultRoot: Bool {
        sameFile(currentRoot, defaultRoot)
    }

    static func scheduleMove(to selectedURL: URL) throws {
        let target = normalize(selectedURL)
        let source = currentRoot
        if sameFile(source, target) {
            var record = readRecord()
            record.pendingRoot = nil
            record.lastMoveError = nil
            record.updatedAt = Date()
            try writeRecord(record)
            return
        }

        try validateTarget(target, source: source)
        var record = readRecord()
        record.pendingRoot = target.path
        record.lastMoveError = nil
        record.updatedAt = Date()
        try writeRecord(record)
    }

    static func resetToDefault() throws {
        try scheduleMove(to: defaultRoot)
    }

    /// Runs before SwiftData, file watchers, and Dome open files. If a prior
    /// Settings action queued a move, copy the full user store, verify it,
    /// flip the fixed locator, then remove the old root.
    static func applyPendingMoveIfNeeded() {
        var record = readRecord()
        guard let pending = record.pendingRoot, !pending.isEmpty else { return }

        let source = record.activeRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            .map(normalize)
            ?? defaultRoot
        let destination = normalize(URL(fileURLWithPath: pending, isDirectory: true))

        do {
            if sameFile(source, destination) {
                record.activeRoot = sameFile(destination, defaultRoot) ? nil : destination.path
                record.pendingRoot = nil
                record.lastMoveError = nil
                record.updatedAt = Date()
                try writeRecord(record)
                return
            }

            try validateTarget(destination, source: source)
            _ = BackupManager.createBackup(reason: "pre-storage-move")
            try copyStore(from: source, to: destination)
            try verifyCopiedStore(from: source, to: destination)

            record.activeRoot = sameFile(destination, defaultRoot) ? nil : destination.path
            record.pendingRoot = nil
            record.lastMoveError = nil
            record.updatedAt = Date()
            try writeRecord(record)

            try pruneSourceStore(source, movedTo: destination)
        } catch {
            record.lastMoveError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            record.updatedAt = Date()
            try? writeRecord(record)
            NSLog("[StorageLocation] move failed: \(record.lastMoveError ?? "unknown error")")
        }
    }

    static func importLegacySwiftDataStoreIfNeeded() {
        let fm = FileManager.default
        let target = swiftDataStoreURL
        guard !fm.fileExists(atPath: target.path) else { return }

        let appSupport = defaultRoot.deletingLastPathComponent()
        let legacy = appSupport.appendingPathComponent("default.store")
        guard fm.fileExists(atPath: legacy.path), looksLikeTadoSwiftDataStore(legacy) else { return }

        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: legacy.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: target.path + suffix)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    static var swiftDataStoreURL: URL {
        currentRoot
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("app-state.store")
    }

    static func readRecord() -> StorageLocationRecord {
        guard let data = AtomicStore.readIfExists(locatorFile),
              let record = try? AtomicStore.jsonDecoder.decode(StorageLocationRecord.self, from: data) else {
            return StorageLocationRecord()
        }
        return record
    }

    // MARK: - Private

    private static func writeRecord(_ record: StorageLocationRecord) throws {
        try AtomicStore.encode(record, to: locatorFile)
    }

    private static func validateTarget(_ target: URL, source: URL) throws {
        let fm = FileManager.default
        let target = normalize(target)
        let source = normalize(source)

        if !sameFile(source, target) {
            if isDescendant(target, of: source) { throw StorageLocationError.targetInsideCurrentStore }
            if isDescendant(source, of: target) { throw StorageLocationError.currentStoreInsideTarget }
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            throw StorageLocationError.targetIsFile(target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        if !isEmptyOrTadoStore(target) {
            throw StorageLocationError.targetContainsUnrelatedFiles(target)
        }

        let probe = target.appendingPathComponent(".tado-write-test-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            throw StorageLocationError.targetNotWritable(target)
        }
    }

    private static func isEmptyOrTadoStore(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return true
        }
        let meaningful = entries.filter { entry in
            let name = entry.lastPathComponent
            return name != ".DS_Store" && name != locatorFileName
        }
        if meaningful.isEmpty { return true }
        return looksLikeTadoStore(url)
    }

    private static func looksLikeTadoStore(_ url: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            url.appendingPathComponent("settings/global.json"),
            url.appendingPathComponent("events"),
            url.appendingPathComponent("memory"),
            url.appendingPathComponent("dome"),
            url.appendingPathComponent("cache"),
            url.appendingPathComponent("backups"),
            url.appendingPathComponent("logs"),
            url.appendingPathComponent("version")
        ]
        return markers.contains { fm.fileExists(atPath: $0.path) }
    }

    private static func copyStore(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return }
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries where shouldMoveStoreEntry(entry, source: source) {
            let dst = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: entry, to: dst)
        }
    }

    private static func verifyCopiedStore(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries where shouldMoveStoreEntry(entry, source: source) {
            let dst = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            guard fm.fileExists(atPath: dst.path) else {
                throw StorageLocationError.copyVerificationFailed(dst)
            }
        }
    }

    private static func pruneSourceStore(_ source: URL, movedTo destination: URL) throws {
        guard !sameFile(source, destination) else { return }
        let fm = FileManager.default
        if sameFile(source, defaultRoot) {
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent != locatorFileName {
                try? fm.removeItem(at: entry)
            }
        } else if fm.fileExists(atPath: source.path) {
            try? fm.removeItem(at: source)
        }
    }

    private static func shouldMoveStoreEntry(_ entry: URL, source: URL) -> Bool {
        !(sameFile(source, defaultRoot) && entry.lastPathComponent == locatorFileName)
    }

    private static func looksLikeTadoSwiftDataStore(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return ["ZTODOITEM", "ZAPPSETTINGS", "ZPROJECT"].allSatisfy { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    private static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        normalize(lhs).path == normalize(rhs).path
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = normalize(child).path
        let parentPath = normalize(parent).path
        guard childPath != parentPath else { return false }
        return childPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }
}
