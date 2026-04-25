import Foundation

/// C2 — Dome as project memory.
///
/// Every Tado project gets a dedicated Dome topic named
/// `project-<first-8-of-uuid>` (sanitized — bt-core's
/// `sanitize_segment` replaces anything that isn't `[a-z0-9-]`).
/// Agents spawned inside the project can discover that topic via
/// `dome_search --topic project-<id>`; the context preamble (C4)
/// pulls the most recent notes from it by default.
///
/// This file groups the Swift call sites that seed or update the
/// topic. All calls are best-effort — if Dome isn't online (first
/// launch, FFI not wired, vault not opened yet), the call returns
/// without error and the topic fills in lazily on the first agent-
/// authored or user-authored write.
enum DomeProjectMemory {
    /// Stable topic id for a project. Short UUID prefix keeps the
    /// slug readable on disk (`topics/project-ab12cd34/...`) while
    /// staying collision-free in any realistic Tado deployment.
    static func topic(for project: Project) -> String {
        "project-" + project.id.uuidString.prefix(8).lowercased()
    }

    /// Seed the project-overview note. Called once at project-create
    /// time from the NewProjectSheet; idempotent on re-call
    /// (bt-core's doc_create rejects a duplicate folder, we swallow
    /// the resulting nil).
    ///
    /// The note's body intentionally leads with the project's
    /// name + root + created-at so the context preamble (C4) can
    /// include it verbatim as the "project" fragment.
    static func seedOverview(for project: Project) {
        let iso = ISO8601DateFormatter().string(from: project.createdAt)
        let body = """
        # \(project.name)

        - **root**: `\(project.rootPath)`
        - **id**: \(project.id.uuidString)
        - **created**: \(iso)

        ## About

        Project-scoped knowledge for the Tado project "\(project.name)".
        Agents spawned in this project can `dome_search --topic \(topic(for: project))`
        to reach decisions, retros, and notes captured here.
        """

        let topic = topic(for: project)
        Task.detached(priority: .utility) {
            _ = DomeRpcClient.writeNote(
                scope: .user,
                topic: topic,
                title: "\(project.name) — overview",
                body: body,
                domeScope: .project(id: project.id, name: project.name, rootPath: project.rootPath, includeGlobal: true),
                knowledgeKind: "system"
            )
        }
    }

    /// Append a structured fact to the project overview. Used by
    /// C5-style retro writers (Eternal / Dispatch completion hooks
    /// that want the UI to see the retro without full Dome-MCP
    /// plumbing on the hook side). Best-effort.
    static func appendOverview(for project: Project, line: String) {
        let topic = topic(for: project)
        // writeNote(replace) overwrites any existing note with the
        // same title — for appends we'd need a separate appendOverview
        // FFI. Until then this helper writes distinct dated entries
        // under the same topic, which is good enough for the UI to
        // surface them as individual notes.
        let title = "note-" + Self.compactStamp()
        Task.detached(priority: .utility) {
            _ = DomeRpcClient.writeNote(
                scope: .user,
                topic: topic,
                title: title,
                body: line,
                domeScope: .project(id: project.id, name: project.name, rootPath: project.rootPath, includeGlobal: true),
                knowledgeKind: "knowledge"
            )
        }
    }

    private static func compactStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
