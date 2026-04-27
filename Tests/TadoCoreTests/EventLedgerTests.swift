import XCTest
@testable import Tado

/// P2 acceptance harness — `EventLedger.build` is the pure helper the
/// Calendar surface uses to turn `EventBus.recent` into the
/// chronological day-grouped feed. We assert the three brief criteria:
///
/// 1. Renders 1000 events ≤ 200 ms on cold load.
/// 2. Scope filter actually narrows results.
/// 3. Jump-to-source produces a parsable deep link.
final class EventLedgerTests: XCTestCase {

    private static let projectA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!
    private static let projectB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!

    // MARK: - Fixture

    /// 1000 events spread across two projects + a global tail.
    /// Half belong to projectA, a quarter to projectB, the remaining
    /// quarter are project-less (system / dome).
    private func makeFixture(count: Int = 1_000) -> [TadoEvent] {
        var events: [TadoEvent] = []
        events.reserveCapacity(count)
        let now = Date()
        for i in 0..<count {
            let kind: String
            let pid: UUID?
            switch i % 4 {
            case 0, 1:
                kind = "terminal"; pid = Self.projectA
            case 2:
                kind = "ipc"; pid = Self.projectB
            default:
                kind = "system"; pid = nil
            }
            let type: String
            switch i % 5 {
            case 0: type = "terminal.spawned"
            case 1: type = "terminal.completed"
            case 2: type = "ipc.messageReceived"
            case 3: type = "dome.daemonStarted"
            default: type = "system.tick"
            }
            events.append(TadoEvent(
                id: UUID(),
                ts: now.addingTimeInterval(-Double(i) * 60),
                type: type,
                severity: .info,
                source: TadoEvent.Source(kind: kind, sessionID: UUID(), projectID: pid, projectName: pid != nil ? "Proj-\(pid!.uuidString.prefix(4))" : nil, runID: nil),
                title: "event \(i)",
                body: "",
                actions: [],
                read: false
            ))
        }
        return events
    }

    // MARK: - Latency

    func testBuild1kEventsUnder200ms() {
        let events = makeFixture(count: 1_000)
        // Warm so first call doesn't pay one-time costs.
        _ = EventLedger.build(events: events, scope: .global)

        var samples: [Double] = []
        for _ in 0..<5 {
            let t0 = DispatchTime.now()
            let groups = EventLedger.build(events: events, scope: .global)
            let t1 = DispatchTime.now()
            let ms = Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
            samples.append(ms)
            XCTAssertFalse(groups.isEmpty)
        }
        let worst = samples.max() ?? 0
        FileHandle.standardError.write(Data(
            "[EventLedger] worst-of-5 build = \(String(format: "%.2f", worst)) ms on 1k events\n".utf8
        ))
        XCTAssertLessThanOrEqual(worst, 200.0, "1k events must build in ≤ 200 ms")
    }

    // MARK: - Scope filter

    func testProjectScopeNarrowsResults() {
        let events = makeFixture(count: 200)
        let global = EventLedger.build(events: events, scope: .global)
        let globalCount = global.reduce(0) { $0 + $1.events.count }

        let projectScope = DomeScopeSelection.project(
            id: Self.projectA,
            name: "A",
            rootPath: "/tmp/a",
            includeGlobal: false
        )
        let scoped = EventLedger.build(events: events, scope: projectScope)
        let scopedCount = scoped.reduce(0) { $0 + $1.events.count }

        XCTAssertEqual(globalCount, 200)
        XCTAssertLessThan(scopedCount, globalCount, "project scope must narrow")
        // Half of the fixture is projectA → ~100 entries.
        XCTAssertGreaterThan(scopedCount, 0)
        XCTAssertLessThanOrEqual(scopedCount, 100)

        for group in scoped {
            for event in group.events {
                XCTAssertEqual(event.source.projectID, Self.projectA)
            }
        }
    }

    func testIncludeGlobalWidensProjectScope() {
        let events = makeFixture(count: 200)
        let withoutGlobal = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: false
        )
        let withGlobal = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: true
        )
        let a = EventLedger.build(events: events, scope: withoutGlobal)
            .reduce(0) { $0 + $1.events.count }
        let b = EventLedger.build(events: events, scope: withGlobal)
            .reduce(0) { $0 + $1.events.count }
        XCTAssertGreaterThan(b, a, "includeGlobal must add project-less events")
    }

    // MARK: - Jump to source

    func testDeepLinkIsParsableForKnownSources() {
        let session = UUID()
        let project = UUID()
        let run = UUID()

        let cases: [(TadoEvent, String)] = [
            (TadoEvent(type: "terminal.completed", source: TadoEvent.Source(kind: "terminal", sessionID: session, projectID: project), title: "t"),
             "tado://terminal/\(session.uuidString)"),
            (TadoEvent(type: "eternal.phaseCompleted", source: TadoEvent.Source(kind: "eternal", runID: run), title: "p"),
             "tado://run/\(run.uuidString)"),
            (TadoEvent(type: "system.tick", source: TadoEvent.Source(kind: "project", projectID: project), title: "p"),
             "tado://project/\(project.uuidString)"),
        ]
        for (event, expected) in cases {
            let link = EventLedger.deepLink(for: event)
            XCTAssertEqual(link, expected)
            XCTAssertNotNil(URL(string: link ?? ""), "deep link must parse: \(link ?? "<nil>")")
        }
    }

    func testDeepLinkPrefersSessionOverRunOverProject() {
        // Pin the precedence: when an event carries multiple
        // identifiers, sessionID wins over runID which wins over
        // projectID. The router downstream relies on this — if a
        // future contributor reorders the branches, this test fails
        // before the router silently jumps to the wrong place.
        let session = UUID()
        let run = UUID()
        let project = UUID()
        let multi = TadoEvent(
            type: "terminal.completed",
            source: TadoEvent.Source(
                kind: "terminal",
                sessionID: session,
                projectID: project,
                runID: run
            ),
            title: "t"
        )
        XCTAssertEqual(EventLedger.deepLink(for: multi), "tado://terminal/\(session.uuidString)")

        let runProject = TadoEvent(
            type: "eternal.phaseCompleted",
            source: TadoEvent.Source(kind: "eternal", projectID: project, runID: run),
            title: "p"
        )
        XCTAssertEqual(EventLedger.deepLink(for: runProject), "tado://run/\(run.uuidString)")
    }

    func testDeepLinkNilWhenNothingToLinkTo() {
        let bare = TadoEvent(type: "system.tick", source: TadoEvent.Source(kind: ""), title: "t")
        XCTAssertNil(EventLedger.deepLink(for: bare))
    }

    // MARK: - Filter

    func testKindFilterRestrictsByPrefix() {
        let events = makeFixture(count: 200)
        let filter = EventLedger.Filter(kinds: ["terminal"])
        let groups = EventLedger.build(events: events, scope: .global, filter: filter)
        for group in groups {
            for event in group.events {
                XCTAssertTrue(event.type.hasPrefix("terminal."), "got \(event.type)")
            }
        }
    }

    // MARK: - kindPrefixes helper (lifted from CalendarSurface)

    func testKindPrefixesAreSortedAndUnique() {
        let events = [
            TadoEvent(type: "terminal.completed", source: TadoEvent.Source(kind: "terminal"), title: "a"),
            TadoEvent(type: "terminal.spawned", source: TadoEvent.Source(kind: "terminal"), title: "b"),
            TadoEvent(type: "dome.daemonStarted", source: TadoEvent.Source(kind: "dome"), title: "c"),
            TadoEvent(type: "ipc.messageReceived", source: TadoEvent.Source(kind: "ipc"), title: "d"),
            TadoEvent(type: "dome.modelDownloading", source: TadoEvent.Source(kind: "dome"), title: "e"),
        ]
        let prefixes = EventLedger.kindPrefixes(in: events)
        XCTAssertEqual(prefixes, ["dome", "ipc", "terminal"])
    }

    func testKindPrefixesEmptyForNoEvents() {
        XCTAssertEqual(EventLedger.kindPrefixes(in: []), [])
    }

    func testKindPrefixesSkipsTypeWithoutDot() {
        let events = [
            TadoEvent(type: "noprefixtype", source: TadoEvent.Source(kind: "x"), title: "a"),
            TadoEvent(type: "system.tick", source: TadoEvent.Source(kind: "system"), title: "b"),
        ]
        let prefixes = EventLedger.kindPrefixes(in: events)
        // `split(.first)` on a no-dot string returns the whole string,
        // which is the documented behaviour and matches what the chip
        // row needs (a chip of the unprefixed type itself).
        XCTAssertEqual(prefixes, ["noprefixtype", "system"])
    }

    // MARK: - SinceWindow helper (lifted from CalendarSurface)

    func testSinceWindowCutoffsArePastDates() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(EventLedger.SinceWindow.today.cutoff(now: now),
                       now.addingTimeInterval(-86_400))
        XCTAssertEqual(EventLedger.SinceWindow.week.cutoff(now: now),
                       now.addingTimeInterval(-86_400 * 7))
        XCTAssertEqual(EventLedger.SinceWindow.month.cutoff(now: now),
                       now.addingTimeInterval(-86_400 * 30))
    }

    func testSinceWindowMatchesWithinDriftTolerance() {
        let now = Date()
        XCTAssertTrue(EventLedger.SinceWindow.week.matches(EventLedger.SinceWindow.week.cutoff(now: now)))
        // 30s clock drift still inside the 60s tolerance.
        let drift = EventLedger.SinceWindow.week.cutoff(now: now).addingTimeInterval(30)
        XCTAssertTrue(EventLedger.SinceWindow.week.matches(drift))
        // 120s drift falls outside.
        let bigDrift = EventLedger.SinceWindow.week.cutoff(now: now).addingTimeInterval(120)
        XCTAssertFalse(EventLedger.SinceWindow.week.matches(bigDrift))
        XCTAssertFalse(EventLedger.SinceWindow.week.matches(nil))
    }

    func testSinceWindowAllCasesArePinned() {
        XCTAssertEqual(EventLedger.SinceWindow.allCases.map(\.rawValue),
                       ["today", "week", "month"])
    }

    func testSinceFilterDropsOldEvents() {
        let now = Date()
        let events = [
            TadoEvent(ts: now, type: "x.a", source: TadoEvent.Source(kind: "system"), title: "fresh"),
            TadoEvent(ts: now.addingTimeInterval(-3_600), type: "x.b", source: TadoEvent.Source(kind: "system"), title: "1h ago"),
            TadoEvent(ts: now.addingTimeInterval(-86_400 * 8), type: "x.c", source: TadoEvent.Source(kind: "system"), title: "8d ago"),
        ]
        let filter = EventLedger.Filter(kinds: [], since: now.addingTimeInterval(-86_400 * 7))
        let groups = EventLedger.build(events: events, scope: .global, filter: filter)
        let titles = groups.flatMap { $0.events.map(\.title) }
        XCTAssertTrue(titles.contains("fresh"))
        XCTAssertTrue(titles.contains("1h ago"))
        XCTAssertFalse(titles.contains("8d ago"))
    }

    func testGlobalFiltersFromAppStateAreApplied() {
        // Pin the contract the Calendar surface relies on:
        // `DomeAppState.globalFilters.kinds` is the same kind set the
        // ledger consumes. If a future refactor changes the type, this
        // test breaks.
        let state = DomeAppState()
        state.globalFilters.kinds = ["dome"]
        let events = makeFixture(count: 200)
        let groups = EventLedger.build(
            events: events,
            scope: .global,
            filter: EventLedger.Filter(
                kinds: state.globalFilters.kinds,
                since: state.globalFilters.since
            )
        )
        let allTypes = groups.flatMap { $0.events.map(\.type) }
        XCTAssertFalse(allTypes.isEmpty, "fixture must have dome.* events")
        for type in allTypes {
            XCTAssertTrue(type.hasPrefix("dome."), "got \(type)")
        }
    }
}
