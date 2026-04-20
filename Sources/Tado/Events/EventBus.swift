import Foundation
import Observation

/// Central publish/subscribe hub for `TadoEvent`s. Every producer in
/// Tado (terminal lifecycle, IPC broker, Eternal/Dispatch services,
/// CLI `tado-notify`, MCP `tado_notify`) calls `EventBus.shared.publish`
/// exactly once per event.
///
/// Publishing flow (order matters; §5.2 of the plan):
///   1. **Durable first** — the event is appended to
///      `events/current.ndjson` via `EventPersister` so history
///      survives a crash/quit between step 1 and any subsequent step.
///   2. **Deliverers** — each registered deliverer (banner, sound,
///      dock badge, system notification, CLI tail) gets the event.
///   3. **Recent ring** — the latest N events are kept in-memory for
///      the in-app history widget; SwiftUI observes `recent`.
///
/// This class is `@MainActor` so SwiftUI observers can read `recent`
/// directly. Persistence runs off-main inside `EventPersister`, so the
/// publish call is cheap — no I/O on the main thread.
@MainActor
@Observable
final class EventBus {
    static let shared = EventBus()

    /// Last `recentCapacity` events, newest at the end. Bounded ring so
    /// long-running sessions don't grow observation graphs unbounded.
    /// The NDJSON log is authoritative for full history.
    private(set) var recent: [TadoEvent] = []

    /// How many events the UI-facing ring keeps. Chosen as "more than
    /// a single long-running session produces in a day" so the history
    /// widget rarely needs to page from the NDJSON archive.
    static let recentCapacity = 500

    @ObservationIgnored private let persister = EventPersister()
    @ObservationIgnored private var deliverers: [(TadoEvent) -> Void] = []

    /// Publish an event. Safe to call from any actor context — hops
    /// to main to update observable state.
    nonisolated func publish(_ event: TadoEvent) {
        Task { @MainActor in self._publish(event) }
    }

    private func _publish(_ event: TadoEvent) {
        persister.append(event)
        for deliverer in deliverers { deliverer(event) }
        recent.append(event)
        if recent.count > Self.recentCapacity {
            recent.removeFirst(recent.count - Self.recentCapacity)
        }
    }

    /// Register an in-process deliverer. Deliverers fire synchronously
    /// on main, so they must not block (use `DispatchQueue.async` or
    /// `Task` internally if needed).
    func addDeliverer(_ handler: @escaping (TadoEvent) -> Void) {
        deliverers.append(handler)
    }

    /// Mark a previously-published event as read (updates the ring
    /// only — the NDJSON log is immutable by design; the "read" state
    /// lives in the ring until persisted UX state lands in a later
    /// packet).
    func markRead(_ id: UUID) {
        guard let idx = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[idx].read = true
    }

    func markAllRead() {
        for idx in recent.indices { recent[idx].read = true }
    }

    /// Count of unread events. Drives the sidebar bell badge and the
    /// Dock icon badge (in Packet 4).
    var unreadCount: Int { recent.reduce(0) { $0 + ($1.read ? 0 : 1) } }
}
