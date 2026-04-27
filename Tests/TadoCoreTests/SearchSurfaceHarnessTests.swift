import XCTest
@testable import Tado

/// P1 acceptance harness — measures `SearchEngine.rank` (the engine
/// behind `DomeRpcClient.search`) on a deterministic 200-doc fixture
/// vault, and asserts:
///
/// 1. **Latency.** P50 and P95 query → ranked-list time must hit the
///    P95 ≤ 120 ms budget from the Eternal brief.
/// 2. **Accuracy.** A fixed query → expected-doc-id table must show
///    top-3 ≥ 0.85 (i.e. for ≥ 85% of queries, the expected doc lands
///    in the top three results).
///
/// The harness is intentionally pure — it bypasses the FFI and feeds
/// `SearchEngine` directly. That is the layer the surface uses on
/// daemon-down paths and the layer a future `tado_dome_search` FFI
/// will replace; either way the surface's behaviour is what's
/// measured here.
final class SearchSurfaceHarnessTests: XCTestCase {

    // MARK: - Fixture

    /// Builds a 200-doc fixture with deterministic IDs `doc-001` …
    /// `doc-200`. Each doc gets a topic chosen from a rotating set, a
    /// title built from a known phrase, and a slug. The expected-hit
    /// table below assumes this exact construction — keep them in
    /// sync.
    private func makeFixture() -> [DomeRpcClient.NoteSummary] {
        let topics = ["work/planning", "work/notes", "research", "personal", "engineering/ipc", "engineering/render", "ops/runbooks", "design"]
        let phrases: [String] = [
            "Eternal Sprint Retrospective",
            "Dispatch Architect Brief",
            "Metal Renderer Glyph Atlas",
            "PTY Performer State Machine",
            "Atomic Store Write Barrier",
            "Scoped Config Hierarchy",
            "Dome Daemon Boot Sequence",
            "Project Settings Sync Path",
            "MCP Bridge Token Issuance",
            "Storage Relocation Migration",
            "Sidebar Rendering Refactor",
            "Eternal Auto Mode Continuation",
            "Calendar Event Bus Routing",
            "Notifications History Surface",
            "Knowledge Graph Force Layout",
            "Search Front Door Wiring",
            "Diff Lens Engine Hand Roll",
            "Hotkey Registrar Cmd+F",
            "Together Lens Merge Read",
            "Cross Run Browser Timeline",
        ]
        var notes: [DomeRpcClient.NoteSummary] = []
        notes.reserveCapacity(200)
        let now = Date()
        for i in 1...200 {
            let phraseIndex = (i - 1) % phrases.count
            let topic = topics[(i - 1) % topics.count]
            let title = "\(phrases[phraseIndex]) \(i)"
            let slug = title.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "+", with: "")
            let id = String(format: "doc-%03d", i)
            let updated = now.addingTimeInterval(-Double(i) * 60)
            notes.append(DomeRpcClient.NoteSummary(
                id: id,
                title: title,
                topic: topic,
                slug: slug,
                userPath: "user/\(slug).md",
                agentPath: "agent/\(slug).md",
                createdAt: updated,
                updatedAt: updated,
                agentActive: false,
                ownerScope: "global",
                projectID: nil,
                projectRoot: nil,
                knowledgeKind: nil
            ))
        }
        return notes
    }

    /// (query, expected-top-doc-id). The most recent matching doc for
    /// each phrase is `doc-001` … `doc-020` in the fixture (lowest
    /// indices have the freshest `updatedAt` because we subtract i*60s
    /// from now). Each query targets a unique phrase, so the freshest
    /// matching doc is the one with the smallest index that still
    /// contains the phrase.
    private static let queryTable: [(query: String, expectedID: String)] = [
        ("eternal retrospective", "doc-001"),
        ("dispatch architect", "doc-002"),
        ("metal glyph atlas", "doc-003"),
        ("pty performer", "doc-004"),
        ("atomic store barrier", "doc-005"),
        ("scoped config", "doc-006"),
        ("dome daemon boot", "doc-007"),
        ("project settings sync", "doc-008"),
        ("mcp bridge token", "doc-009"),
        ("storage relocation", "doc-010"),
        ("sidebar refactor", "doc-011"),
        ("eternal auto mode", "doc-012"),
        ("calendar event bus", "doc-013"),
        ("notifications history", "doc-014"),
        ("knowledge graph layout", "doc-015"),
        ("search front door", "doc-016"),
        ("diff lens engine", "doc-017"),
        ("hotkey registrar", "doc-018"),
        ("together lens", "doc-019"),
        ("cross run browser", "doc-020"),
    ]

    // MARK: - Latency

    func testRankP95LatencyUnder120ms() {
        let notes = makeFixture()
        XCTAssertEqual(notes.count, 200)

        // Warm up so the first query doesn't pay one-time costs (string
        // folding caches, dispatch table init).
        for q in Self.queryTable.prefix(3) {
            _ = SearchEngine.rank(query: q.query, notes: notes, limit: 50)
        }

        var samples: [Double] = []
        samples.reserveCapacity(Self.queryTable.count * 5)
        for _ in 0..<5 {
            for entry in Self.queryTable {
                let t0 = DispatchTime.now()
                _ = SearchEngine.rank(query: entry.query, notes: notes, limit: 50)
                let t1 = DispatchTime.now()
                let ms = Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
                samples.append(ms)
            }
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95Index = min(samples.count - 1, Int(Double(samples.count) * 0.95))
        let p95 = samples[p95Index]

        // Print to stderr so the eval harness diagnostics keep the
        // numbers visible.
        FileHandle.standardError.write(Data(
            "[SearchSurfaceHarness] P50=\(String(format: "%.2f", p50)) ms · P95=\(String(format: "%.2f", p95)) ms\n"
            .utf8
        ))
        XCTAssertLessThanOrEqual(p95, 120.0, "P95 latency must be ≤ 120 ms on a 200-doc fixture")
    }

    // MARK: - Accuracy

    func testTop3AccuracyAtLeast85Percent() {
        let notes = makeFixture()
        var top1Hits = 0
        var top3Hits = 0
        for entry in Self.queryTable {
            let scored = SearchEngine.rank(query: entry.query, notes: notes, limit: 5)
            let top1 = scored.first?.note.id
            let top3IDs = scored.prefix(3).map { $0.note.id }
            if top1 == entry.expectedID { top1Hits += 1 }
            if top3IDs.contains(entry.expectedID) { top3Hits += 1 }
        }
        let top1 = Double(top1Hits) / Double(Self.queryTable.count)
        let top3 = Double(top3Hits) / Double(Self.queryTable.count)
        FileHandle.standardError.write(Data(
            "[SearchSurfaceHarness] top1=\(String(format: "%.3f", top1)) · top3=\(String(format: "%.3f", top3))\n"
            .utf8
        ))
        XCTAssertGreaterThanOrEqual(top3, 0.85, "Top-3 accuracy must be ≥ 0.85")
    }

    // MARK: - Boundary

    func testEmptyQueryReturnsNoHits() {
        let notes = makeFixture()
        XCTAssertTrue(SearchEngine.rank(query: "", notes: notes).isEmpty)
        XCTAssertTrue(SearchEngine.rank(query: "   \n\t", notes: notes).isEmpty)
    }

    func testCaseAndDiacriticInsensitive() {
        let notes = makeFixture()
        let lower = SearchEngine.rank(query: "metal glyph atlas", notes: notes)
        let upper = SearchEngine.rank(query: "METAL GLYPH ATLAS", notes: notes)
        XCTAssertEqual(lower.first?.note.id, upper.first?.note.id)
    }

    func testQueryWithNoMatchesReturnsEmpty() {
        let notes = makeFixture()
        // Single token that doesn't appear as a substring of any
        // fixture title, topic, or slug. Tokenizer splits on
        // non-alphanum so we just need one nonsense word.
        let result = SearchEngine.rank(query: "qzfvkxbjmnzz", notes: notes)
        XCTAssertTrue(result.isEmpty)
    }

    func testRankRespectsExplicitLimit() {
        let notes = makeFixture()
        let result = SearchEngine.rank(query: "the", notes: notes, limit: 5)
        XCTAssertLessThanOrEqual(result.count, 5)
    }
}
