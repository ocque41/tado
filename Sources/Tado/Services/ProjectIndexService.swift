import Foundation
import SwiftData

/// Mirrors the SwiftData `Project` table to a flat JSON index at
/// `<storage-root>/projects.json` so external CLI clients (the Rust
/// `tado-projects list/resolve` binaries and, by extension, the
/// natural-language coordinator agent) can resolve project names →
/// root paths without an IPC round-trip into the running app.
///
/// The canonical store remains SwiftData; this index is a
/// rebuildable cache, atomic on every write. If the index file
/// disappears, the next save rewrites it. If SwiftData and the
/// index disagree, SwiftData wins on the next save.
///
/// Lives next to `RunEventWatcher` in the app's startup chain — it
/// observes `ModelContext.didSave` and rebuilds the file whenever
/// projects are added, renamed, moved, or deleted. Cheap: project
/// counts on a single-user laptop are in the dozens, not millions.
///
/// Lifetime: held strongly by `TadoApp` for the app's whole run;
/// no explicit teardown needed. Tying observer cleanup to deinit
/// would require nonisolated access patterns we don't gain anything
/// from — the observer self-removes when the process exits.
@MainActor
@Observable
final class ProjectIndexService {
    private let modelContext: ModelContext
    @ObservationIgnored
    private var observer: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // Write the index once on launch so a fresh CLI run after a
        // clean install can read the file even if the user hasn't
        // mutated any projects yet this session.
        rewrite()

        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rewrite()
            }
        }
    }

    /// One-shot rebuild. Idempotent — the AtomicStore writes a
    /// temp file, fsyncs, renames, so a partial read while a write
    /// is in flight gets either the old or the new contents but
    /// never a torn JSON document.
    func rewrite() {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        guard let projects = try? modelContext.fetch(descriptor) else { return }
        let entries = projects.map { ProjectIndexEntry(project: $0) }
        do {
            try AtomicStore.encode(entries, to: StorePaths.projectsIndexFile)
        } catch {
            NSLog("[Tado] ProjectIndexService rewrite failed: \(error)")
        }
    }
}

/// Wire format mirrored to `projects.json`. Stable contract — Rust
/// CLIs decode this exact shape via serde. Renaming a field here
/// requires updating the Rust `Project` struct in `tado-cli` AND
/// shipping a migration that double-writes the old shape long enough
/// for existing CLI binaries to be rebuilt.
struct ProjectIndexEntry: Codable, Equatable {
    let id: UUID
    let name: String
    let rootPath: String
    let createdAt: Date

    init(project: Project) {
        self.id = project.id
        self.name = project.name
        self.rootPath = project.rootPath
        self.createdAt = project.createdAt
    }
}
