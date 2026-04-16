import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    var dispatchMarkdown: String = ""
    var dispatchState: String = "idle"  // "idle" | "drafted" | "planning" | "dispatching"

    init(name: String, rootPath: String) {
        self.id = UUID()
        self.name = name
        self.rootPath = rootPath
        self.createdAt = Date()
    }
}
