import Foundation

enum DomeScopeSelection: Identifiable, Equatable {
    case global
    case project(id: UUID, name: String, rootPath: String, includeGlobal: Bool)

    var id: String {
        switch self {
        case .global:
            return "global"
        case .project(let id, _, _, let includeGlobal):
            return id.uuidString + ":" + (includeGlobal ? "merged" : "project")
        }
    }

    var label: String {
        switch self {
        case .global:
            return "Global"
        case .project(_, let name, _, _):
            return name
        }
    }

    var ownerScope: String {
        switch self {
        case .global: return "global"
        case .project: return "project"
        }
    }

    var readKnowledgeScope: String {
        switch self {
        case .global: return "global"
        case .project(_, _, _, let includeGlobal):
            return includeGlobal ? "merged" : "project"
        }
    }

    var includeGlobal: Bool {
        switch self {
        case .global: return false
        case .project(_, _, _, let includeGlobal): return includeGlobal
        }
    }

    var projectIDString: String? {
        switch self {
        case .global:
            return nil
        case .project(let id, _, _, _):
            return id.uuidString
        }
    }

    var projectRoot: String? {
        switch self {
        case .global:
            return nil
        case .project(_, _, let rootPath, _):
            return rootPath
        }
    }

    var defaultTopic: String {
        switch self {
        case .global:
            return "user"
        case .project(let id, _, _, _):
            return "project-" + id.uuidString.prefix(8).lowercased()
        }
    }

    var inheritedGlobalReadOnly: Bool {
        if case .project(_, _, _, let includeGlobal) = self { return includeGlobal }
        return false
    }
}
