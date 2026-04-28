import Foundation

enum StorePaths {
    static let appName = "Tado"

    static var root: URL {
        StorageLocationManager.currentRoot
    }

    static var defaultRoot: URL { StorageLocationManager.defaultRoot }
    static var storageLocatorFile: URL { StorageLocationManager.locatorFile }

    static var settingsDir: URL { sub("settings") }
    static var memoryDir: URL { sub("memory") }
    static var eventsDir: URL { sub("events") }
    static var eventsArchiveDir: URL { sub("events/archive") }
    static var logsDir: URL { sub("logs") }
    static var cacheDir: URL { sub("cache") }
    static var backupsDir: URL { sub("backups") }
    static var binDir: URL { sub("bin") }

    static var globalSettingsFile: URL { settingsDir.appendingPathComponent("global.json") }
    static var userMemoryMarkdown: URL { memoryDir.appendingPathComponent("user.md") }
    static var userMemoryJSON: URL { memoryDir.appendingPathComponent("user.json") }
    static var eventsCurrent: URL { eventsDir.appendingPathComponent("current.ndjson") }
    static var versionFile: URL { root.appendingPathComponent("version") }

    /// `<root>/dome` — vault root opened by bt-core. v0.12+
    /// surfaces (`dome-eval` runner, audit log viewer) need the
    /// path to compose the SQLite-file URL, so it lives here next
    /// to the other storage-root accessors instead of in Dome
    /// extension code.
    static var domeVaultRoot: URL { sub("dome") }

    /// `<root>/dome/.bt/index.sqlite` — the SQLite file bt-core
    /// uses for its trusted-mutator state.
    static var domeIndexDB: URL {
        domeVaultRoot
            .appendingPathComponent(".bt", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    static func projectTadoDir(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".tado", isDirectory: true)
    }

    static func projectConfigFile(projectRoot: URL) -> URL {
        projectTadoDir(projectRoot: projectRoot).appendingPathComponent("config.json")
    }

    static func projectLocalFile(projectRoot: URL) -> URL {
        projectTadoDir(projectRoot: projectRoot).appendingPathComponent("local.json")
    }

    static func projectMemoryDir(projectRoot: URL) -> URL {
        projectTadoDir(projectRoot: projectRoot).appendingPathComponent("memory", isDirectory: true)
    }

    @discardableResult
    private static func sub(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
