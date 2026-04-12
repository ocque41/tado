import Foundation
import SwiftData

@Model
final class Team {
    var id: UUID
    var name: String
    var projectID: UUID
    var agentNames: [String]
    var createdAt: Date

    init(name: String, projectID: UUID, agentNames: [String] = []) {
        self.id = UUID()
        self.name = name
        self.projectID = projectID
        self.agentNames = agentNames
        self.createdAt = Date()
    }
}
