import Foundation

/// Pure helper that turns a flat `[TadoEvent]` into the chronological
/// "Agent Activity Ledger" the Calendar surface renders. Lifted out of
/// the SwiftUI view so it can be unit-tested for latency and scope
/// filter correctness without spinning up a window.
///
/// Two responsibilities:
///   1. **Filter** by Dome scope + optional kind chips + optional
///      since-cutoff. When `scope` is `.project(id, …)`, an event is
///      kept iff `event.source.projectID == id` — global events
///      (no project) are folded in iff `includeGlobal` is true.
///   2. **Group** the surviving events by `Calendar.current.startOfDay`
///      and sort each day's bucket newest-first. Days are returned
///      newest-first so the ledger renders top-down.
enum EventLedger {

    struct DayGroup: Equatable {
        let day: Date
        let events: [TadoEvent]
    }

    struct Filter: Equatable {
        var kinds: Set<String>
        var since: Date?

        init(kinds: Set<String> = [], since: Date? = nil) {
            self.kinds = kinds
            self.since = since
        }
    }

    /// Ledger build: filter → sort → group → bucket-sort.
    /// Deterministic and allocation-light — the P2 acceptance harness
    /// asserts ≤ 200 ms on 1000 events.
    static func build(
        events: [TadoEvent],
        scope: DomeScopeSelection,
        filter: Filter = Filter(),
        calendar: Calendar = .current
    ) -> [DayGroup] {
        let scoped = applyScope(events, scope: scope)
        let filtered = applyFilter(scoped, filter: filter)
        // One sort + one O(n) group pass instead of Dictionary(grouping:)
        // → array-of-keys → re-sort, which doubles allocations.
        let sortedDesc = filtered.sorted { $0.ts > $1.ts }
        var groups: [DayGroup] = []
        var currentDay: Date? = nil
        var currentBucket: [TadoEvent] = []
        for event in sortedDesc {
            let day = calendar.startOfDay(for: event.ts)
            if currentDay == day {
                currentBucket.append(event)
            } else {
                if let d = currentDay { groups.append(DayGroup(day: d, events: currentBucket)) }
                currentDay = day
                currentBucket = [event]
            }
        }
        if let d = currentDay { groups.append(DayGroup(day: d, events: currentBucket)) }
        return groups
    }

    /// Scope filter. Encodes the brief's "scope filter actually narrows
    /// results" rule: project scopes only see events whose source's
    /// `projectID` matches; `includeGlobal` widens that to also let
    /// project-less events through.
    static func applyScope(
        _ events: [TadoEvent],
        scope: DomeScopeSelection
    ) -> [TadoEvent] {
        switch scope {
        case .global:
            return events
        case .project(let projectID, _, _, let includeGlobal):
            return events.filter { event in
                if let pid = event.source.projectID {
                    return pid == projectID
                }
                return includeGlobal
            }
        }
    }

    static func applyFilter(_ events: [TadoEvent], filter: Filter) -> [TadoEvent] {
        guard !filter.kinds.isEmpty || filter.since != nil else { return events }
        return events.filter { event in
            if let cutoff = filter.since, event.ts < cutoff { return false }
            if !filter.kinds.isEmpty {
                let prefix = String(event.type.split(separator: ".").first ?? "")
                if !filter.kinds.contains(event.type) && !filter.kinds.contains(prefix) {
                    return false
                }
            }
            return true
        }
    }

    /// Build a `tado://` deep-link string for an event. The app's URL
    /// router will resolve `terminal://<sessionID>` style entries into
    /// the matching tile in P6's hotkey/breadcrumb work. Until then the
    /// surface uses these strings as the click-to-jump payload — the
    /// harness asserts they are URL-parsable so the contract is fixed
    /// before consumers land.
    /// Stable union of kind prefixes across `events`. The Calendar
    /// surface uses this to populate its chip row so the user only
    /// sees filters they can actually toggle. Sorted alphabetically
    /// for predictable ordering across reloads.
    static func kindPrefixes(in events: [TadoEvent]) -> [String] {
        var prefixes = Set<String>()
        for event in events {
            if let head = event.type.split(separator: ".").first {
                prefixes.insert(String(head))
            }
        }
        return prefixes.sorted()
    }

    /// Pre-baked since-window choices the chip row exposes. Lifted
    /// into the helper so the chip math (which `Date` value to assign
    /// to `globalFilters.since`, and which range an existing filter
    /// matches) lives next to the filter logic that consumes it.
    enum SinceWindow: String, CaseIterable, Identifiable {
        case today
        case week
        case month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .week: return "Week"
            case .month: return "Month"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .today: return 86_400
            case .week: return 86_400 * 7
            case .month: return 86_400 * 30
            }
        }
        /// Compute the cutoff `Date` for a given window relative to
        /// `now`. The chip handler assigns the result to
        /// `DomeAppState.globalFilters.since` so the ledger filter
        /// drops anything older.
        func cutoff(now: Date = Date()) -> Date {
            now.addingTimeInterval(-seconds)
        }
        /// True when `cutoff(now:)` matches the supplied date within a
        /// minute — handles small clock drift between the moment a
        /// chip was tapped and the moment the matcher runs.
        func matches(_ date: Date?, now: Date = Date()) -> Bool {
            guard let date else { return false }
            return abs(cutoff(now: now).timeIntervalSince(date)) < 60
        }
    }

    static func deepLink(for event: TadoEvent) -> String? {
        let kind = event.source.kind.isEmpty ? "system" : event.source.kind
        if let session = event.source.sessionID {
            return "tado://\(kind)/\(session.uuidString)"
        }
        if let run = event.source.runID {
            return "tado://run/\(run.uuidString)"
        }
        if let project = event.source.projectID {
            return "tado://project/\(project.uuidString)"
        }
        if event.type.hasPrefix("dome.") {
            return "tado://dome/\(event.id.uuidString)"
        }
        return nil
    }
}
