import Foundation

struct AgentDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let filePath: String
    let source: AgentSource

    enum AgentSource: String {
        case claude
        case codex
    }

    init(id: String, filePath: String, source: AgentSource) {
        self.id = id
        self.name = id
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
        self.filePath = filePath
        self.source = source
    }
}
