import Foundation
import SwiftData

/// A one-shot, idempotent schema migration for Tado's persistence
/// layer. Each migration has a monotonic integer ID. The runner
/// applies migrations whose ID > the stored version-marker, in
/// ascending order, and bumps the marker after each success.
///
/// Rules:
///   - `id` strictly increases across releases (001, 002, ...).
///   - `apply(context:)` MUST be safe to call twice in a row
///     (idempotent) in case a migration half-finished and we retry.
///   - Migrations can read from SwiftData (via `context`) and the
///     persistence layer (via `AtomicStore` + `StorePaths`). They
///     cannot depend on app UI state.
protocol Migration {
    var id: Int { get }
    var name: String { get }
    func apply(context: ModelContext) throws
}
