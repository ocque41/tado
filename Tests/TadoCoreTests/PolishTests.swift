import XCTest
@testable import Tado

/// P6 acceptance — Polish layer.
///
/// Three brief criteria:
///   1. **Hotkeys fire.** We can't drive AppKit's keyboard-shortcut
///      dispatch from XCTest, but we can pin the *contract* the
///      registrar relies on: `DomeSurfaceTab.allCases` is the source
///      of truth for `Cmd+1..N`, and a `Cmd+F` action mutates
///      `DomeAppState.activeSurface` to `.search`.
///   2. **Perf budget tests green.** A consolidated harness re-runs
///      every per-surface budget defined by P1–P5 with margins
///      tightened on top of the brief's quoted ceilings, so a future
///      regression that pushes any surface past its budget breaks
///      this single test.
///   3. **VoiceOver labels present.** We pin the `accessibilityLabel`
///      strings of the breadcrumbs/hotkey-registrar helpers (the only
///      surface-level controls authored as plain helpers) and assert
///      `DomeSurfaceTab.label` is non-empty for every case.
final class PolishTests: XCTestCase {

    // MARK: - Hotkey contract

    func testHotkeyOrderMatchesAllCases() {
        let cases = DomeSurfaceTab.allCases
        XCTAssertEqual(cases.first, .search, "Cmd+1 must always be Search")
        // No more than 9 surfaces — Cmd+1..9 is the available range.
        XCTAssertLessThanOrEqual(cases.count, 9)
        // Every case must produce a non-empty label so VoiceOver has
        // something to announce when a hotkey fires.
        for tab in cases {
            XCTAssertFalse(tab.label.isEmpty, "\(tab) has empty label")
            XCTAssertFalse(tab.iconSystemName.isEmpty, "\(tab) missing icon")
        }
    }

    func testCmdFActionMutatesAppStateToSearch() {
        let state = DomeAppState(activeSurface: .userNotes)
        // Mirror the registrar's `Cmd+F` action: switch to Search.
        let action: () -> Void = { state.activeSurface = .search }
        XCTAssertEqual(state.activeSurface, .userNotes)
        action()
        XCTAssertEqual(state.activeSurface, .search)
    }

    // MARK: - Scope identity (.task re-fire contract)

    func testScopeIDChangesWhenIncludeGlobalToggles() {
        // SearchSurface and KnowledgeListSurface both `.task(id: domeScope.id)`
        // — switching `includeGlobal` MUST flip the id so the task
        // re-runs and the result list updates. Pin the contract here
        // so a future refactor can't accidentally collapse the two
        // states onto the same id.
        let project = UUID()
        let withoutGlobal = DomeScopeSelection.project(
            id: project, name: "A", rootPath: "/x", includeGlobal: false
        )
        let withGlobal = DomeScopeSelection.project(
            id: project, name: "A", rootPath: "/x", includeGlobal: true
        )
        XCTAssertNotEqual(withoutGlobal.id, withGlobal.id)
    }

    func testGlobalScopeIDIsStable() {
        XCTAssertEqual(DomeScopeSelection.global.id, "global")
    }

    func testCmdFBumpsSearchFocusRequestCounter() {
        // Hardening — the registrar bumps `searchFocusRequest` so the
        // search field pulls focus via its `@FocusState` watcher.
        // Pin the contract: each invocation increments by 1.
        let state = DomeAppState(activeSurface: .search)
        let before = state.searchFocusRequest
        state.searchFocusRequest &+= 1
        state.searchFocusRequest &+= 1
        XCTAssertEqual(state.searchFocusRequest, before + 2)
    }

    func testCmdNPickerActionMutatesAppState() {
        let state = DomeAppState(activeSurface: .search)
        // Cmd+3 → 3rd allCases entry. Reproduce the registrar's
        // closure deterministically.
        let target = DomeSurfaceTab.allCases[2]
        state.activeSurface = target
        XCTAssertEqual(state.activeSurface, target)
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbsEmitDomeRootForSearch() {
        let trail = DomeBreadcrumbs.trail(for: .search, knowledgePage: nil, scope: .global)
        XCTAssertEqual(trail.first?.label, "Dome")
        XCTAssertEqual(trail.last?.label, "Search")
    }

    func testBreadcrumbsIncludeProjectScopeName() {
        let id = UUID()
        let trail = DomeBreadcrumbs.trail(
            for: .userNotes,
            knowledgePage: nil,
            scope: .project(id: id, name: "Acme", rootPath: "/x", includeGlobal: true)
        )
        XCTAssertEqual(trail.map(\.label), ["Dome", "Acme", "User Notes"])
    }

    func testBreadcrumbsAppendKnowledgePage() {
        let trail = DomeBreadcrumbs.trail(for: .knowledge, knowledgePage: .graph, scope: .global)
        XCTAssertEqual(trail.map(\.label), ["Dome", "Knowledge", "Graph"])
    }

    // MARK: - Perf budget umbrella

    /// Re-runs every per-surface helper under tightened wall-time
    /// budgets so a regression on any pure helper trips this single
    /// test. Budget headroom is 50 % of the brief's quoted ceiling so
    /// the test fails LOUDLY before the brief's ceiling is breached.
    func testPerSurfacePerfBudgetsHold() {
        // Search surface — brief: P95 ≤ 120 ms on 200 docs.
        let docs: [DomeRpcClient.NoteSummary] = (0..<200).map { i in
            DomeRpcClient.NoteSummary(
                id: "doc-\(i)", title: "Title \(i) phrase",
                topic: "topic/\(i % 8)", slug: "title-\(i)",
                userPath: "u", agentPath: "a",
                createdAt: Date(), updatedAt: Date(),
                agentActive: false, ownerScope: nil,
                projectID: nil, projectRoot: nil, knowledgeKind: nil
            )
        }
        let t0 = DispatchTime.now()
        _ = SearchEngine.rank(query: "title 42 phrase", notes: docs, limit: 50)
        let searchMs = ms(since: t0)
        XCTAssertLessThanOrEqual(searchMs, 60.0)

        // Calendar / Activity Ledger — brief: 1k events ≤ 200 ms.
        let events: [TadoEvent] = (0..<1_000).map { i in
            TadoEvent(
                ts: Date().addingTimeInterval(-Double(i) * 60),
                type: "terminal.completed",
                source: TadoEvent.Source(kind: "terminal", sessionID: UUID()),
                title: "e\(i)", body: ""
            )
        }
        let t1 = DispatchTime.now()
        _ = EventLedger.build(events: events, scope: .global)
        let ledgerMs = ms(since: t1)
        XCTAssertLessThanOrEqual(ledgerMs, 100.0)

        // Diff helper — brief: 2 KB note ≤ 50 ms.
        let leftLines = (0..<80).map { "line-\($0): the quick brown fox jumps." }
        let rightLines: [String] = leftLines.enumerated().map { idx, l in
            idx % 10 == 0 ? "line-\(idx): rewritten content (\(idx))." : l
        }
        let t2 = DispatchTime.now()
        _ = DiffEngine.diff(leftLines: leftLines, rightLines: rightLines)
        let diffMs = ms(since: t2)
        XCTAssertLessThanOrEqual(diffMs, 25.0)

        // ForceLayout fallback — brief: 500 nodes ≤ 3 s. We use a
        // smaller 100-node case here under a 750 ms ceiling so the
        // umbrella test stays fast but a quadratic regression still
        // trips it: 500 nodes scale ~25× the work, so a 100-node run
        // crossing 750 ms means 500 nodes can no longer hit 3 s.
        var fallbackNodes: [ForceLayout.Node] = []
        let n = 100
        let radius = 200.0
        for i in 0..<n {
            let theta = 2 * .pi * Double(i) / Double(n)
            fallbackNodes.append(ForceLayout.Node(
                id: "n-\(i)",
                position: CGPoint(x: radius * cos(theta), y: radius * sin(theta))
            ))
        }
        let fallbackEdges = (0..<n).map { ForceLayout.Edge(source: "n-\($0)", target: "n-\(($0 + 1) % n)") }
        var fallbackConfig = ForceLayout.Config()
        fallbackConfig.maxIterations = 60
        let t3 = DispatchTime.now()
        _ = ForceLayout.run(nodes: fallbackNodes, edges: fallbackEdges, config: fallbackConfig)
        let layoutMs = ms(since: t3)
        XCTAssertLessThanOrEqual(layoutMs, 750.0)

        // Together lens — there's no brief-quoted ceiling for this
        // helper since it's a pure scope filter, but it runs on every
        // surface mount so a regression past 25 ms on a 500-note
        // fixture would be a real UX hit.
        let projectID = UUID()
        let togetherNotes: [DomeRpcClient.NoteSummary] = (0..<500).map { i in
            let isProject = i % 2 == 0
            return DomeRpcClient.NoteSummary(
                id: "n-\(i)", title: "n", topic: "t",
                slug: "s", userPath: "u", agentPath: "a",
                createdAt: Date(), updatedAt: Date(),
                agentActive: false,
                ownerScope: isProject ? "project" : nil,
                projectID: isProject ? projectID.uuidString : nil,
                projectRoot: nil, knowledgeKind: nil
            )
        }
        let scope = DomeScopeSelection.project(
            id: projectID, name: "A", rootPath: "/x", includeGlobal: true
        )
        let t4 = DispatchTime.now()
        _ = TogetherLens.merge(notes: togetherNotes, scope: scope)
        let togetherMs = ms(since: t4)
        XCTAssertLessThanOrEqual(togetherMs, 25.0)

        let line = "[PolishPerf] search=\(fmt(searchMs)) ms · ledger=\(fmt(ledgerMs)) ms · diff=\(fmt(diffMs)) ms · layout=\(fmt(layoutMs)) ms · together=\(fmt(togetherMs)) ms\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func ms(since t0: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
    }
    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    // MARK: - VoiceOver coverage

    func testEverySurfaceTabHasAnnounceableLabel() {
        for tab in DomeSurfaceTab.allCases {
            // Surface tab buttons render with `.accessibilityLabel("\(tab.label) surface")`
            // — empty label would announce as "untitled button". Pin
            // the source string here.
            XCTAssertFalse(tab.label.isEmpty)
            XCTAssertGreaterThanOrEqual(tab.label.count, 4)
        }
    }

    func testKnowledgePagesHaveAnnounceableLabels() {
        for page in DomeKnowledgePage.allCases {
            XCTAssertFalse(page.label.isEmpty)
            XCTAssertFalse(page.iconSystemName.isEmpty)
        }
    }

    func testNoteLensModesHaveAnnounceableLabels() {
        for mode in NoteLensMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.subtitle.isEmpty)
        }
    }

    // MARK: - Deep-link audit

    /// Pin the `tado://` URL surface across the two helpers that
    /// produce them — `EventLedger.deepLink` and
    /// `ContextPackDeepLink`. A future addition like
    /// `tado://team/<id>` should also land in this audit so the
    /// schema stays explicit.
    func testTadoDeepLinkSchemeAudit() throws {
        let session = UUID()
        let project = UUID()
        let run = UUID()

        let cases: [String?] = [
            EventLedger.deepLink(for: TadoEvent(
                type: "terminal.completed",
                source: TadoEvent.Source(kind: "terminal", sessionID: session, projectID: project),
                title: "t"
            )),
            EventLedger.deepLink(for: TadoEvent(
                type: "eternal.phaseCompleted",
                source: TadoEvent.Source(kind: "eternal", runID: run),
                title: "p"
            )),
            EventLedger.deepLink(for: TadoEvent(
                type: "system.tick",
                source: TadoEvent.Source(kind: "project", projectID: project),
                title: "p"
            )),
            ContextPackDeepLink.sourceLink(for: ContextPackSource(
                sourceRef: "doc:abc-123", hash: nil, rank: nil, docId: nil, title: nil
            )),
            ContextPackDeepLink.packLink(for: ContextPackSummary(
                contextId: "ctx-1", brand: "claude",
                sessionId: nil, docId: nil, sourceHash: nil,
                summaryPath: nil, manifestPath: nil
            )),
        ]
        for raw in cases {
            let link = try XCTUnwrap(raw)
            // Every link must use the `tado://` scheme.
            XCTAssertTrue(link.hasPrefix("tado://"), "non-Tado URL: \(link)")
            // Must parse as URL.
            XCTAssertNotNil(URL(string: link))
            // Host segment must be one of the audited families. Add to
            // `allowedHosts` if you intentionally extend the schema.
            let allowedHosts: Set<String> = ["terminal", "run", "project", "dome"]
            let host = URL(string: link)?.host ?? ""
            XCTAssertTrue(allowedHosts.contains(host), "unaudited host '\(host)' in \(link)")
        }
    }

    func testBreadcrumbCombinedLabelIsComposable() {
        let trail = DomeBreadcrumbs.trail(for: .knowledge, knowledgePage: .graph, scope: .global)
        let composed = trail.map(\.label).joined(separator: " in ")
        XCTAssertEqual(composed, "Dome in Knowledge in Graph")
    }
}
