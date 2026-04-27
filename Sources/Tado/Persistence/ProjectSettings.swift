import Foundation

/// In-memory / on-disk representation of `<project>/.tado/config.json`
/// (scope 3, project-shared) and `.tado/local.json` (scope 2,
/// project-local). Same shape for both files — `local.json` values
/// override `config.json` values field-by-field when merging.
///
/// This is the canonical source of truth for per-project settings;
/// mirrored into the SwiftData `Project` row by `ProjectSettingsSync`
/// so SwiftUI `@Query` observers redraw on JSON edits.
struct ProjectSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var writer: String = "tado-app"
    var updatedAt: Date = Date()

    /// Governs how `.tado/.gitignore` is written. Only meaningful in
    /// `config.json` (the shared file) — `local.json` ignores it.
    var commitPolicy: CommitPolicy = .shared

    var project: ProjectIdentity = ProjectIdentity()
    var engine: EngineBlock = EngineBlock()
    var eternal: EternalBlock = EternalBlock()
    var dispatch: DispatchBlock = DispatchBlock()
    var notifications: NotificationsBlock = NotificationsBlock()
    var dome: DomeBlock = DomeBlock()

    enum CommitPolicy: String, Codable, CaseIterable {
        /// `config.json` tracked by git, `local.json` gitignored.
        /// Teams share Eternal sprint prompts, preferred engine, etc.
        case shared
        /// Both files treated as local; `.tado/.gitignore` extends to
        /// include `config.json`. Nothing Tado-specific leaks to git.
        case localOnly = "local-only"
        /// Tado does not manage `.tado/.gitignore` at all.
        case none
    }

    struct ProjectIdentity: Codable, Equatable {
        var name: String = ""
    }

    struct EngineBlock: Codable, Equatable {
        /// Empty string → inherit from global. Non-empty overrides.
        var `default`: String = ""
    }

    struct EternalBlock: Codable, Equatable {
        var mode: String = "mega"
        var loopKind: String = "external"
        var completionMarker: String = "ETERNAL-DONE"
        var sprintEval: String = ""
        var sprintImprove: String = ""
        var skipPermissions: Bool = true
    }

    /// Reserved for future dispatch-level config. Empty today so the
    /// file layout doesn't churn when we start populating it.
    struct DispatchBlock: Codable, Equatable {}

    struct DomeBlock: Codable, Equatable {
        /// nil = inherit (`globalSettings.includeGlobalInProject`).
        /// .some = explicit per-project override.
        ///
        /// Why optional: a plain `Bool` default conflates "user
        /// explicitly set to default" with "never set", so the merge
        /// step silently drops the explicit value. Optional makes
        /// explicitness representable, so toggle round-trips work.
        var includeGlobal: Bool? = nil
        var defaultKnowledgeKind: String = "knowledge"
        var agentRegistrationEnabled: Bool = true
        var advancedWorkflowsEnabled: Bool = true
    }

    /// Project-level override for event routing. Keys match the
    /// event-type taxonomy in `GlobalSettings.defaultEventRouting`.
    /// Missing keys fall through to the global routing table.
    struct NotificationsBlock: Codable, Equatable {
        var eventRouting: [String: [String]] = [:]
    }
}
