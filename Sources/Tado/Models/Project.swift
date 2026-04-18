import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    var dispatchMarkdown: String = ""
    /// State machine for the project's dispatch lifecycle.
    /// `idle` → no dispatch started.
    /// `drafted` → user typed a brief in the modal but hasn't hit Accept yet
    /// (used by the modal to prefill on reopen).
    /// `planning` → architect is running, no plan on disk yet (or incomplete).
    /// `dispatching` → plan is on disk, phase 1+ running, chain alive.
    /// `stalled` → the watchdog stopped seeing progress before the chain
    /// reached the last phase. Paired with `stalledAtPhase`.
    var dispatchState: String = "idle"
    /// When `dispatchState == "stalled"`, the order value of the phase the
    /// watchdog believes got stuck (one past the last completed phase).
    /// Nil otherwise.
    var stalledAtPhase: Int? = nil

    init(name: String, rootPath: String) {
        self.id = UUID()
        self.name = name
        self.rootPath = rootPath
        self.createdAt = Date()
    }
}
