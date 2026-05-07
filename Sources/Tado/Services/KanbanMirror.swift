import Foundation
import SwiftData

/// File-based mirror for a project's general Kanban board.
///
/// Tado's canvas / project page are SwiftData-backed, but agents
/// running on the canvas need a way to read and manipulate the board
/// without any SwiftUI runtime. The `tado-kanban` CLI and the
/// `tado_kanban_*` MCP family talk to plain JSON on disk; this service
/// is the bridge that keeps the SwiftData truth and the JSON mirror in
/// agreement.
///
/// On-disk shape, written atomically through `AtomicStore`:
/// ```
/// <project>/.tado/kanban/
///   state.json     — { generation, columns: [...], cards: [...] }
///   inbox/         — *.json files agents drop to request mutations
///                    (e.g. `move-<uuid>.json`). The watcher applies
///                    each one to SwiftData and removes it on success.
/// ```
///
/// The `generation` counter increments on every write the Swift side
/// makes. Agent-issued mutations carry the generation they observed;
/// a stale generation is logged but still applied (last-write-wins —
/// no agent-vs-human conflict resolution UI for v1, since the agents
/// also see the human's writes through the mirror).
@MainActor
enum KanbanMirror {
    /// Project-scoped on-disk root. Created lazily on the first write.
    static func kanbanRoot(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("kanban")
    }

    static func stateFileURL(_ project: Project) -> URL {
        kanbanRoot(project).appendingPathComponent("state.json")
    }

    static func inboxDirURL(_ project: Project) -> URL {
        kanbanRoot(project).appendingPathComponent("inbox")
    }

    /// Read the most-recently mirrored generation counter for this
    /// project. Used by agent CLIs that want to no-op when their
    /// observed generation is already stale.
    static func currentGeneration(_ project: Project) -> Int {
        let url = stateFileURL(project)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(KanbanMirrorState.self, from: data) else {
            return 0
        }
        return decoded.generation
    }

    /// Snapshot the project's current Kanban state and write it to the
    /// mirror. Caller is expected to hold the @MainActor and to have
    /// just made (or not made) any SwiftData mutation — this only
    /// reads.
    static func writeMirror(
        project: Project,
        modelContext: ModelContext,
        bumpGeneration: Bool = true
    ) {
        let projectID = project.id
        let columnDescriptor = FetchDescriptor<KanbanColumn>(
            predicate: #Predicate<KanbanColumn> { col in
                col.kind == "project" && col.project?.id == projectID
            }
        )
        let columns = ((try? modelContext.fetch(columnDescriptor)) ?? [])
            .sorted { $0.orderIndex < $1.orderIndex }
        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> { todo in
                todo.projectID == projectID
            }
        )
        let todos = ((try? modelContext.fetch(todoDescriptor)) ?? [])
            .filter { $0.listStateRaw == ListState.active.rawValue }

        let prevGen = currentGeneration(project)
        let nextGen = bumpGeneration ? prevGen + 1 : prevGen

        let state = KanbanMirrorState(
            generation: nextGen,
            project: KanbanMirrorProject(
                id: project.id.uuidString,
                name: project.name,
                root: project.rootPath
            ),
            columns: columns.map { col in
                KanbanMirrorColumn(
                    id: col.id.uuidString,
                    columnKey: col.columnKey,
                    title: col.title,
                    orderIndex: col.orderIndex
                )
            },
            cards: todos.map { todo in
                KanbanMirrorCard(
                    id: todo.id.uuidString,
                    text: todo.displayName,
                    columnKey: todo.kanbanColumnKey,
                    orderIndex: todo.kanbanOrderIndex,
                    status: todo.statusRaw,
                    agent: todo.agentName,
                    createdAt: ISO8601DateFormatter().string(from: todo.createdAt)
                )
            }
        )

        let root = kanbanRoot(project)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: inboxDirURL(project), withIntermediateDirectories: true)

        let url = stateFileURL(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        // Atomic write — temp + fsync + rename. Matches the project
        // convention for on-disk JSON (see CLAUDE.md "Atomic-store
        // discipline"). FileManager's `.atomic` option uses
        // `rename(2)` semantics on macOS, which is what we want here.
        try? data.write(to: url, options: [.atomic])
    }

    /// Apply a single agent-issued mutation file to SwiftData and
    /// remove it from the inbox. Idempotent (skipped if the target
    /// todo is missing or already in the requested column). Called by
    /// the inbox watcher.
    static func applyInboxFile(
        url: URL,
        project: Project,
        modelContext: ModelContext
    ) {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(KanbanInboxEnvelope.self, from: data) else {
            // Malformed file — drop it so we don't keep retrying. Agents
            // can re-issue if they see no mirror update.
            try? FileManager.default.removeItem(at: url)
            return
        }

        switch envelope.kind {
        case "move-card":
            applyMoveCard(envelope: envelope, project: project, modelContext: modelContext)
        case "add-column":
            applyAddColumn(envelope: envelope, project: project, modelContext: modelContext)
        default:
            // Unknown kind — log and remove. v1 only ships the two
            // mutations above; future kinds add cases here.
            NSLog("KanbanMirror: ignoring unknown inbox kind '\(envelope.kind)' from \(url.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: url)
        writeMirror(project: project, modelContext: modelContext)
    }

    private static func applyMoveCard(
        envelope: KanbanInboxEnvelope,
        project: Project,
        modelContext: ModelContext
    ) {
        guard let cardIDString = envelope.cardID,
              let cardID = UUID(uuidString: cardIDString),
              let columnKey = envelope.columnKey else { return }
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> { $0.id == cardID }
        )
        guard let todo = try? modelContext.fetch(descriptor).first else { return }
        guard todo.projectID == project.id else { return }
        guard todo.kanbanColumnKey != columnKey else { return }
        // Append: bottom of the destination column.
        let projectID = project.id
        let inColumn = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> { $0.projectID == projectID && $0.kanbanColumnKey == columnKey }
        )
        let dest = (try? modelContext.fetch(inColumn)) ?? []
        let nextIndex = (dest.map(\.kanbanOrderIndex).max() ?? -1) + 1
        todo.kanbanColumnKey = columnKey
        todo.kanbanOrderIndex = nextIndex
        try? modelContext.save()
    }

    private static func applyAddColumn(
        envelope: KanbanInboxEnvelope,
        project: Project,
        modelContext: ModelContext
    ) {
        guard let title = envelope.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        let key = envelope.columnKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "col-\(UUID().uuidString.prefix(8).lowercased())"
        let projectID = project.id
        let exists = FetchDescriptor<KanbanColumn>(
            predicate: #Predicate<KanbanColumn> { col in
                col.kind == "project" && col.project?.id == projectID && col.columnKey == key
            }
        )
        if let already = try? modelContext.fetch(exists), !already.isEmpty {
            return
        }
        let columnsDescriptor = FetchDescriptor<KanbanColumn>(
            predicate: #Predicate<KanbanColumn> { col in
                col.kind == "project" && col.project?.id == projectID
            }
        )
        let existing = (try? modelContext.fetch(columnsDescriptor)) ?? []
        let nextOrder = (existing.map(\.orderIndex).max() ?? -1) + 1
        let col = KanbanColumn(
            project: project,
            kind: "project",
            columnKey: key,
            title: title,
            orderIndex: nextOrder
        )
        modelContext.insert(col)
        try? modelContext.save()
    }
}

// MARK: - On-disk shape

struct KanbanMirrorState: Codable {
    var generation: Int
    var project: KanbanMirrorProject
    var columns: [KanbanMirrorColumn]
    var cards: [KanbanMirrorCard]
}

struct KanbanMirrorProject: Codable {
    var id: String
    var name: String
    var root: String
}

struct KanbanMirrorColumn: Codable {
    var id: String
    var columnKey: String
    var title: String
    var orderIndex: Int
}

struct KanbanMirrorCard: Codable {
    var id: String
    var text: String
    var columnKey: String?
    var orderIndex: Int
    var status: String
    var agent: String?
    var createdAt: String
}

/// Envelope for agent-issued inbox files. Schema is union-typed by
/// `kind`; unused fields are ignored. Future mutation kinds add fields
/// here without breaking previous-version parsers.
struct KanbanInboxEnvelope: Codable {
    var kind: String              // "move-card" | "add-column"
    var cardID: String?           // for "move-card"
    var columnKey: String?        // for both
    var title: String?            // for "add-column"
    var observedGeneration: Int?  // optional — agents may include
    var sender: String?           // optional — informational only
}
