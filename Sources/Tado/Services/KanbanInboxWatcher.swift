import Foundation
import SwiftData

/// Watches every project's `<.tado>/kanban/inbox/` directory for
/// agent-issued mutation files (e.g. `move-<uuid>.json`,
/// `add-column-<uuid>.json`) and applies each one to SwiftData via
/// `KanbanMirror.applyInboxFile`.
///
/// Sister to `RunEventWatcher` — same shape (per-row FileWatcher,
/// reattached on `ModelContext.didSave` so newly-created projects
/// auto-attach), but covers a different on-disk surface.
@MainActor
final class KanbanInboxWatcher {
    private let container: ModelContainer
    private let context: ModelContext
    private var saveObserver: NSObjectProtocol?

    private var watchers: [UUID: FileWatcher] = [:]

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    func start() {
        attachAll()
        // Re-scan on every SwiftData save so a newly-created project
        // auto-attaches its inbox watcher. Same pattern as
        // `RunEventWatcher.start`.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attachAll()
                self?.refreshMirrorsFromDidSave()
            }
        }
    }

    private func attachAll() {
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? context.fetch(descriptor)) ?? []
        let liveIDs = Set(projects.map(\.id))

        for project in projects {
            if watchers[project.id] != nil { continue }
            let inbox = KanbanMirror.inboxDirURL(project)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let projectID = project.id
            let watcher = FileWatcher(url: inbox) { [weak self] in
                Task { @MainActor in self?.drainInbox(projectID: projectID) }
            }
            watchers[project.id] = watcher
            // Initial drain in case agents wrote files while the app
            // was quit. Idempotent — `applyInboxFile` removes each
            // file on success, and rewrites the mirror afterwards.
            drainInbox(projectID: project.id)
        }

        // Detach watchers for deleted projects so we don't leak fds.
        for (id, _) in watchers where !liveIDs.contains(id) {
            watchers[id]?.cancel()
            watchers.removeValue(forKey: id)
        }
    }

    /// Re-write each project's mirror after a SwiftData save so the
    /// JSON tracks any UI mutation the user made. The mirror write is
    /// cheap (one prettyPrinted JSON file per project), but we still
    /// debounce by short-circuiting when the project has no kanban
    /// columns yet — the seed step only runs when the user opens the
    /// board, so most projects on disk will skip this branch.
    private func refreshMirrorsFromDidSave() {
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? context.fetch(descriptor)) ?? []
        for project in projects {
            let projectID = project.id
            let columnsDescriptor = FetchDescriptor<KanbanColumn>(
                predicate: #Predicate<KanbanColumn> { col in
                    col.kind == "project" && col.project?.id == projectID
                }
            )
            let columns = (try? context.fetch(columnsDescriptor)) ?? []
            guard !columns.isEmpty else { continue }
            KanbanMirror.writeMirror(project: project, modelContext: context)
        }
    }

    private func drainInbox(projectID: UUID) {
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? context.fetch(descriptor),
              let project = projects.first(where: { $0.id == projectID }) else { return }
        let inbox = KanbanMirror.inboxDirURL(project)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        ) else { return }
        // Sort by name so a burst of files applies in a deterministic
        // order. Agents typically encode a timestamp prefix.
        let sorted = entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sorted {
            KanbanMirror.applyInboxFile(
                url: url,
                project: project,
                modelContext: context
            )
        }
    }
}
