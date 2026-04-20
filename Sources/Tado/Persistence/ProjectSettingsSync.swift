import Foundation
import SwiftData

/// Keeps each SwiftData `Project` row synchronized with its
/// `<rootPath>/.tado/config.json` + `local.json` files.
///
/// Direction of flow (mirrors `AppSettingsSync`):
///   - **JSON → SwiftData**: on bootstrap, and on every ScopedConfig
///     `.projectShared` / `.projectLocal` change fire. Applies merged
///     `ProjectSettings` values onto the matching `Project` row.
///   - **SwiftData → JSON**: after every `ModelContext.didSave`, diff
///     each `Project` row against the in-memory shared settings. If
///     different, push the delta to `ScopedConfig.setProjectShared`.
///
/// Bootstrap side-effect: any `Project` whose `.tado/config.json` is
/// missing gets one seeded from its SwiftData fields (idempotent).
/// New projects created after launch are picked up by the next
/// `didSave` — the sync creates the JSON file on first mirror.
///
/// `rootPath` is the keying URL. All lookups go through
/// `ScopedConfig.getProject(at:)` which standardizes + resolves
/// symlinks, so `/foo` and `/foo/` collapse.
@MainActor
final class ProjectSettingsSync {
    private let container: ModelContainer
    private let context: ModelContext
    private var saveObserver: NSObjectProtocol?

    /// Project rootPaths (as URL keys) we have already bootstrapped.
    /// Prevents re-seeding on every didSave.
    private var bootstrapped: Set<URL> = []

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    func start() {
        bootstrapAllProjects()

        // JSON → SwiftData on external edits of any project's files.
        ScopedConfig.shared.addOnChange { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .global:
                return
            case .projectShared(let url), .projectLocal(let url):
                self.applyJSONToSwiftData(projectRootURL: url)
            }
        }

        // SwiftData → JSON on any save. Covers new-project creation,
        // rename, and field edits made through SwiftUI bindings.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushSwiftDataToJSON() }
        }
    }

    // MARK: - Bootstrap

    private func bootstrapAllProjects() {
        let descriptor = FetchDescriptor<Project>()
        guard let rows = try? context.fetch(descriptor) else { return }
        for row in rows {
            let url = projectURL(for: row)
            bootstrapProject(row, at: url)
            bootstrapped.insert(url)
        }
    }

    /// Seed `<rootPath>/.tado/config.json` from the Project row if the
    /// file is missing. Otherwise, pull JSON values onto the row so
    /// SwiftUI picks up whatever the file says. Either way, the row
    /// and the file end up consistent.
    private func bootstrapProject(_ row: Project, at url: URL) {
        let configPath = StorePaths.projectConfigFile(projectRoot: url)
        if !FileManager.default.fileExists(atPath: configPath.path) {
            // Seed from SwiftData row.
            var shared = ProjectSettings()
            shared.project.name = row.name
            shared.eternal.mode = row.eternalMode
            shared.eternal.loopKind = row.eternalLoopKind
            shared.eternal.completionMarker = row.eternalCompletionMarker
            shared.eternal.sprintEval = row.eternalSprintEval
            shared.eternal.sprintImprove = row.eternalSprintImprove
            shared.eternal.skipPermissions = row.eternalSkipPermissions
            ScopedConfig.shared.setProjectShared(at: url) { $0 = shared }
        } else {
            // File already there — reconcile row against merged view.
            applyJSONToSwiftData(projectRootURL: url)
        }
        // Ensure the teammate-facing README exists. Idempotent: never
        // overwrites a hand-edited copy.
        Migration002_CreateProjectJSON.writeTeammateReadme(projectRoot: url)
    }

    // MARK: - JSON → SwiftData

    private func applyJSONToSwiftData(projectRootURL url: URL) {
        guard let row = findProject(at: url) else { return }
        let merged = ScopedConfig.shared.getProject(at: url)

        if !merged.project.name.isEmpty, row.name != merged.project.name {
            row.name = merged.project.name
        }
        if row.eternalMode != merged.eternal.mode {
            row.eternalMode = merged.eternal.mode
        }
        if row.eternalLoopKind != merged.eternal.loopKind {
            row.eternalLoopKind = merged.eternal.loopKind
        }
        if row.eternalCompletionMarker != merged.eternal.completionMarker {
            row.eternalCompletionMarker = merged.eternal.completionMarker
        }
        if row.eternalSprintEval != merged.eternal.sprintEval {
            row.eternalSprintEval = merged.eternal.sprintEval
        }
        if row.eternalSprintImprove != merged.eternal.sprintImprove {
            row.eternalSprintImprove = merged.eternal.sprintImprove
        }
        if row.eternalSkipPermissions != merged.eternal.skipPermissions {
            row.eternalSkipPermissions = merged.eternal.skipPermissions
        }

        try? context.save()
    }

    // MARK: - SwiftData → JSON

    private func pushSwiftDataToJSON() {
        let descriptor = FetchDescriptor<Project>()
        guard let rows = try? context.fetch(descriptor) else { return }

        for row in rows {
            let url = projectURL(for: row)
            // New projects: bootstrap (creates file from row fields).
            if !bootstrapped.contains(url) {
                bootstrapProject(row, at: url)
                bootstrapped.insert(url)
                continue
            }

            let currentShared = ScopedConfig.shared.getProjectShared(at: url)
            var next = currentShared
            next.project.name = row.name
            next.eternal.mode = row.eternalMode
            next.eternal.loopKind = row.eternalLoopKind
            next.eternal.completionMarker = row.eternalCompletionMarker
            next.eternal.sprintEval = row.eternalSprintEval
            next.eternal.sprintImprove = row.eternalSprintImprove
            next.eternal.skipPermissions = row.eternalSkipPermissions

            // Equality compare ignoring writer/updatedAt so JSON→SwiftData
            // reflection doesn't ping-pong into another file write.
            var a = currentShared; a.writer = ""; a.updatedAt = .distantPast
            var b = next;           b.writer = ""; b.updatedAt = .distantPast
            guard a != b else { continue }

            ScopedConfig.shared.setProjectShared(at: url) { $0 = next }
        }
    }

    // MARK: - Helpers

    private func findProject(at url: URL) -> Project? {
        let descriptor = FetchDescriptor<Project>()
        guard let rows = try? context.fetch(descriptor) else { return nil }
        return rows.first { projectURL(for: $0) == url }
    }

    private func projectURL(for project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
