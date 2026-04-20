import Foundation

enum StorePaths {
    static let appName = "Tado"

    static var root: URL {
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = (base ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent(appName, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
