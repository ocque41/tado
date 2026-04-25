import Foundation

/// Facade for reading + writing Tado's persistent config across five
/// scopes (§4.1 of the architecture plan):
///
///   1. Runtime      — CLI flag or env var (not managed here)
///   2. Project-local — `<project>/.tado/local.json`       (this file)
///   3. Project-shared — `<project>/.tado/config.json`      (this file)
///   4. User-global  — `~/Library/Application Support/Tado/settings/global.json`
///   5. Built-in default — Swift struct literal             (this file)
///
/// Reads merge bottom-up: each higher-precedence scope overrides
/// matching keys in the lower one. For the global scope this is
/// trivial (defaults → `global.json`). For project reads we merge
/// global → project-shared → project-local.
///
/// Writes go through `AtomicStore` (lock + tmp + rename) and bump
/// `updatedAt` + `writer`. File changes from external editors / CLI
/// fire `FileWatcher` events that reload the in-memory cache and
/// notify subscribers.
///
/// Subscribers receive a `Scope` enum with an optional project root
/// URL so a single handler can route changes correctly whether they
/// came from `global.json` or a specific project's `.tado/*.json`.
@MainActor
final class ScopedConfig {
    static let shared = ScopedConfig()

    enum Scope: Equatable {
        case global
        case projectShared(URL)
        case projectLocal(URL)
    }

    // MARK: - Global state

    private(set) var globalSettings: GlobalSettings = GlobalSettings()
    private var globalWatcher: FileWatcher?
    private let writerTag: String
    private var lastGlobalSelfWriteAt: Date = .distantPast
    private var onChangeHandlers: [(Scope) -> Void] = []

    // MARK: - Project state

    /// Cached per-project settings, keyed by project root URL
    /// (standardized so `/foo` and `/foo/` collapse).
    private var projectSharedCache: [URL: ProjectSettings] = [:]
    private var projectLocalCache: [URL: ProjectSettings] = [:]
    private var projectWatchers: [URL: (FileWatcher, FileWatcher)] = [:]
    private var lastProjectSelfWriteAt: [URL: Date] = [:]

    init(writerTag: String = "tado-app") {
        self.writerTag = writerTag
    }

    // MARK: - Lifecycle

    /// Call once at app launch after `MigrationRunner.run()` has
    /// materialized `global.json`. Loads from disk and starts watching.
    /// Per-project scopes activate on first access via
    /// `loadProject(at:)`.
    func bootstrap() {
        loadGlobal()
        startWatchingGlobal()
    }

    func addOnChange(_ handler: @escaping (Scope) -> Void) {
        onChangeHandlers.append(handler)
    }

    // MARK: - Read: global

    func get() -> GlobalSettings { globalSettings }

    // MARK: - Write: global

    /// Replace the in-memory global settings and persist to disk
    /// atomically. Bumps `updatedAt` and `writer`.
    func setGlobal(_ mutate: (inout GlobalSettings) -> Void) {
        var next = globalSettings
        mutate(&next)
        next.writer = writerTag
        next.updatedAt = Date()
        writeGlobal(next)
    }

    /// Wholesale overwrite (used by import). Caller owns setting
    /// `writer`/`updatedAt`.
    func replaceGlobal(_ value: GlobalSettings) {
        writeGlobal(value)
    }

    // MARK: - Read: project

    /// Merged project view: defaults → shared (`config.json`) → local
    /// (`local.json`). The returned struct is a snapshot; call sites
    /// that want to write should use `setProjectShared` /
    /// `setProjectLocal` rather than mutating the copy.
    func getProject(at rootPath: URL) -> ProjectSettings {
        let key = key(for: rootPath)
        loadProjectIfNeeded(at: key)
        let shared = projectSharedCache[key] ?? ProjectSettings()
        let local = projectLocalCache[key] ?? ProjectSettings()
        return merge(shared: shared, local: local)
    }

    /// Read the raw project-shared settings (what will be written to
    /// `config.json`). Used by the Settings UI when editing shared
    /// fields so the picker doesn't show merged local overrides.
    func getProjectShared(at rootPath: URL) -> ProjectSettings {
        let key = key(for: rootPath)
        loadProjectIfNeeded(at: key)
        return projectSharedCache[key] ?? ProjectSettings()
    }

    /// Read the raw project-local settings (what will be written to
    /// `local.json`). Returns all-default if the file is missing.
    func getProjectLocal(at rootPath: URL) -> ProjectSettings {
        let key = key(for: rootPath)
        loadProjectIfNeeded(at: key)
        return projectLocalCache[key] ?? ProjectSettings()
    }

    // MARK: - Write: project

    /// Mutate + atomically persist `<project>/.tado/config.json`.
    /// Also rewrites `.tado/.gitignore` if `commitPolicy` changed.
    func setProjectShared(at rootPath: URL, _ mutate: (inout ProjectSettings) -> Void) {
        let key = key(for: rootPath)
        loadProjectIfNeeded(at: key)
        var next = projectSharedCache[key] ?? ProjectSettings()
        mutate(&next)
        next.writer = writerTag
        next.updatedAt = Date()
        writeProjectShared(next, at: key)
    }

    /// Mutate + atomically persist `<project>/.tado/local.json`.
    /// `commitPolicy` on this file is ignored — only `config.json`
    /// governs gitignore.
    func setProjectLocal(at rootPath: URL, _ mutate: (inout ProjectSettings) -> Void) {
        let key = key(for: rootPath)
        loadProjectIfNeeded(at: key)
        var next = projectLocalCache[key] ?? ProjectSettings()
        mutate(&next)
        next.writer = writerTag
        next.updatedAt = Date()
        writeProjectLocal(next, at: key)
    }

    /// Stop watching a project's config files. Called when a project
    /// is removed from SwiftData so we don't leak fds.
    func forgetProject(at rootPath: URL) {
        let key = key(for: rootPath)
        projectWatchers[key]?.0.cancel()
        projectWatchers[key]?.1.cancel()
        projectWatchers.removeValue(forKey: key)
        projectSharedCache.removeValue(forKey: key)
        projectLocalCache.removeValue(forKey: key)
        lastProjectSelfWriteAt.removeValue(forKey: key)
    }

    // MARK: - Private: global

    private func loadGlobal() {
        if let data = AtomicStore.readIfExists(StorePaths.globalSettingsFile),
           let parsed = try? AtomicStore.jsonDecoder.decode(GlobalSettings.self, from: data) {
            globalSettings = parsed
        } else {
            globalSettings = GlobalSettings()
        }
    }

    private func writeGlobal(_ next: GlobalSettings) {
        do {
            try AtomicStore.encode(next, to: StorePaths.globalSettingsFile)
            globalSettings = next
            lastGlobalSelfWriteAt = Date()
        } catch {
            NSLog("[ScopedConfig] global write failed: \(error)")
        }
    }

    private func startWatchingGlobal() {
        globalWatcher = FileWatcher(url: StorePaths.globalSettingsFile) { [weak self] in
            guard let self else { return }
            // Ignore watcher fires triggered by our own recent write.
            // Editors/CLI writers will be far enough from a self-write
            // that the 500ms window doesn't suppress real external edits.
            if Date().timeIntervalSince(self.lastGlobalSelfWriteAt) < 0.5 { return }
            self.loadGlobal()
            for handler in self.onChangeHandlers { handler(.global) }
        }
    }

    // MARK: - Private: project

    private func key(for rootPath: URL) -> URL {
        rootPath.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func loadProjectIfNeeded(at key: URL) {
        guard projectWatchers[key] == nil else { return }
        loadProjectShared(at: key)
        loadProjectLocal(at: key)
        startWatchingProject(at: key)
    }

    private func loadProjectShared(at key: URL) {
        let url = StorePaths.projectConfigFile(projectRoot: key)
        if let data = AtomicStore.readIfExists(url),
           let parsed = try? AtomicStore.jsonDecoder.decode(ProjectSettings.self, from: data) {
            projectSharedCache[key] = parsed
        } else {
            projectSharedCache[key] = ProjectSettings()
        }
    }

    private func loadProjectLocal(at key: URL) {
        let url = StorePaths.projectLocalFile(projectRoot: key)
        if let data = AtomicStore.readIfExists(url),
           let parsed = try? AtomicStore.jsonDecoder.decode(ProjectSettings.self, from: data) {
            projectLocalCache[key] = parsed
        } else {
            projectLocalCache[key] = ProjectSettings()
        }
    }

    private func writeProjectShared(_ next: ProjectSettings, at key: URL) {
        let url = StorePaths.projectConfigFile(projectRoot: key)
        do {
            try AtomicStore.encode(next, to: url)
            projectSharedCache[key] = next
            lastProjectSelfWriteAt[key] = Date()
            // Keep .tado/.gitignore aligned with the declared policy.
            // Runs unconditionally — even a no-op commitPolicy value
            // heals a user-edited gitignore on the next write.
            ProjectGitignore.apply(policy: next.commitPolicy, projectRoot: key)
        } catch {
            NSLog("[ScopedConfig] project shared write failed at \(url.path): \(error)")
        }
    }

    private func writeProjectLocal(_ next: ProjectSettings, at key: URL) {
        let url = StorePaths.projectLocalFile(projectRoot: key)
        do {
            try AtomicStore.encode(next, to: url)
            projectLocalCache[key] = next
            lastProjectSelfWriteAt[key] = Date()
        } catch {
            NSLog("[ScopedConfig] project local write failed at \(url.path): \(error)")
        }
    }

    private func startWatchingProject(at key: URL) {
        let sharedURL = StorePaths.projectConfigFile(projectRoot: key)
        let localURL = StorePaths.projectLocalFile(projectRoot: key)

        let sharedWatcher = FileWatcher(url: sharedURL) { [weak self] in
            guard let self else { return }
            if let last = self.lastProjectSelfWriteAt[key],
               Date().timeIntervalSince(last) < 0.5 { return }
            self.loadProjectShared(at: key)
            for handler in self.onChangeHandlers { handler(.projectShared(key)) }
        }
        let localWatcher = FileWatcher(url: localURL) { [weak self] in
            guard let self else { return }
            if let last = self.lastProjectSelfWriteAt[key],
               Date().timeIntervalSince(last) < 0.5 { return }
            self.loadProjectLocal(at: key)
            for handler in self.onChangeHandlers { handler(.projectLocal(key)) }
        }
        projectWatchers[key] = (sharedWatcher, localWatcher)
    }

    // MARK: - Merge

    /// Field-level override merge: `local` values replace `shared`
    /// values only when `local` holds a non-default. This lets a
    /// teammate commit `config.json` with a meaningful value and
    /// lets each machine override via `local.json` without every
    /// machine also needing every other field filled in.
    private func merge(shared: ProjectSettings, local: ProjectSettings) -> ProjectSettings {
        let defaults = ProjectSettings()
        var out = shared

        // Engine
        if local.engine.default != defaults.engine.default {
            out.engine.default = local.engine.default
        }

        // Eternal
        if local.eternal.mode != defaults.eternal.mode {
            out.eternal.mode = local.eternal.mode
        }
        if local.eternal.loopKind != defaults.eternal.loopKind {
            out.eternal.loopKind = local.eternal.loopKind
        }
        if local.eternal.completionMarker != defaults.eternal.completionMarker {
            out.eternal.completionMarker = local.eternal.completionMarker
        }
        if local.eternal.sprintEval != defaults.eternal.sprintEval {
            out.eternal.sprintEval = local.eternal.sprintEval
        }
        if local.eternal.sprintImprove != defaults.eternal.sprintImprove {
            out.eternal.sprintImprove = local.eternal.sprintImprove
        }
        if local.eternal.skipPermissions != defaults.eternal.skipPermissions {
            out.eternal.skipPermissions = local.eternal.skipPermissions
        }

        // Notifications — local overrides (key-wise merge).
        if !local.notifications.eventRouting.isEmpty {
            var routing = shared.notifications.eventRouting
            for (k, v) in local.notifications.eventRouting { routing[k] = v }
            out.notifications.eventRouting = routing
        }

        // Dome
        if local.dome.includeGlobal != defaults.dome.includeGlobal {
            out.dome.includeGlobal = local.dome.includeGlobal
        }
        if local.dome.defaultKnowledgeKind != defaults.dome.defaultKnowledgeKind {
            out.dome.defaultKnowledgeKind = local.dome.defaultKnowledgeKind
        }
        if local.dome.agentRegistrationEnabled != defaults.dome.agentRegistrationEnabled {
            out.dome.agentRegistrationEnabled = local.dome.agentRegistrationEnabled
        }
        if local.dome.advancedWorkflowsEnabled != defaults.dome.advancedWorkflowsEnabled {
            out.dome.advancedWorkflowsEnabled = local.dome.advancedWorkflowsEnabled
        }

        return out
    }
}
