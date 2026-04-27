import Foundation

/// "Together" lens — the merged read-only view that spans the global
/// scope and the active project for a given note topic. Unlike Diff,
/// Together does not compare versions; it surfaces every note that
/// would be visible under "global ∪ active project (when
/// includeGlobalData)" so the user can read across scopes without
/// switching the picker.
///
/// Lifted out of the SwiftUI surface so the P4/P5 acceptance harnesses
/// can pin the brief's "Together respects includeGlobalData" rule
/// without booting a window. Pure: input is a flat note list (already
/// fetched from `DomeRpcClient.listNotes`), output is the merged list
/// scoped + sorted newest-first.
enum TogetherLens {

    /// Merge `notes` against the active scope.
    ///   - `.global`             → all notes pass.
    ///   - `.project(id, …, includeGlobal: true)`  → project notes
    ///     PLUS global / project-less notes.
    ///   - `.project(id, …, includeGlobal: false)` → project notes only.
    static func merge(
        notes: [DomeRpcClient.NoteSummary],
        scope: DomeScopeSelection
    ) -> [DomeRpcClient.NoteSummary] {
        switch scope {
        case .global:
            return notes.sorted { $0.sortTimestamp > $1.sortTimestamp }
        case .project(_, _, _, let includeGlobal):
            let ownerHint = scopeOwnerHint(for: scope)
            let filtered = notes.filter { note in
                if isProjectScoped(note: note, scope: scope) { return true }
                if includeGlobal && isGlobalNote(note) { return true }
                _ = ownerHint
                return false
            }
            return filtered.sorted { $0.sortTimestamp > $1.sortTimestamp }
        }
    }

    /// True if `note` belongs to the active project scope.
    static func isProjectScoped(
        note: DomeRpcClient.NoteSummary,
        scope: DomeScopeSelection
    ) -> Bool {
        switch scope {
        case .global:
            return false
        case .project(let id, _, _, _):
            // Match either project_id (preferred) or owner_scope == "project"
            // when project_id is missing — bt-core sets one or the other
            // depending on which write path produced the note.
            if let pid = note.projectID, pid == id.uuidString.lowercased() { return true }
            if let pid = note.projectID, pid == id.uuidString { return true }
            return false
        }
    }

    /// True if the note is a "global" / scope-less note — fair game
    /// for the project-with-`includeGlobal` lens.
    static func isGlobalNote(_ note: DomeRpcClient.NoteSummary) -> Bool {
        if let owner = note.ownerScope, owner == "project" { return false }
        if note.projectID != nil { return false }
        return true
    }

    private static func scopeOwnerHint(for scope: DomeScopeSelection) -> String {
        switch scope {
        case .global: return "global"
        case .project: return "project"
        }
    }
}
