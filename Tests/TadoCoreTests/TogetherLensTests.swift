import XCTest
@testable import Tado

/// P4 acceptance harness — Together lens scope rules. Pinning the
/// brief's "Together respects includeGlobalData" rule.
final class TogetherLensTests: XCTestCase {

    private static let projectA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let projectAString = projectA.uuidString

    private func note(
        id: String,
        title: String,
        ownerScope: String?,
        projectID: String?,
        ts: Date = Date()
    ) -> DomeRpcClient.NoteSummary {
        DomeRpcClient.NoteSummary(
            id: id,
            title: title,
            topic: "user",
            slug: id,
            userPath: "user/\(id).md",
            agentPath: "agent/\(id).md",
            createdAt: ts,
            updatedAt: ts,
            agentActive: false,
            ownerScope: ownerScope,
            projectID: projectID,
            projectRoot: nil,
            knowledgeKind: nil
        )
    }

    private func fixture() -> [DomeRpcClient.NoteSummary] {
        let now = Date()
        return [
            note(id: "g1", title: "Global one", ownerScope: nil, projectID: nil, ts: now),
            note(id: "g2", title: "Global two", ownerScope: "global", projectID: nil, ts: now.addingTimeInterval(-60)),
            note(id: "p1", title: "Project A", ownerScope: "project", projectID: Self.projectAString, ts: now.addingTimeInterval(-30)),
            note(id: "p2", title: "Project A two", ownerScope: "project", projectID: Self.projectAString, ts: now.addingTimeInterval(-90)),
            note(id: "x1", title: "Project X", ownerScope: "project", projectID: "deadbeef-deaf-beef-deaf-beefdeafbeef", ts: now.addingTimeInterval(-200)),
        ]
    }

    func testGlobalScopeShowsEverything() {
        let merged = TogetherLens.merge(notes: fixture(), scope: .global)
        XCTAssertEqual(merged.count, 5)
        // Newest-first ordering.
        XCTAssertEqual(merged.first?.id, "g1")
    }

    func testProjectScopeWithoutGlobalShowsOnlyProjectNotes() {
        let scope = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: false
        )
        let merged = TogetherLens.merge(notes: fixture(), scope: scope)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.id)), Set(["p1", "p2"]))
    }

    func testProjectScopeWithGlobalAddsGlobalNotes() {
        let scope = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: true
        )
        let merged = TogetherLens.merge(notes: fixture(), scope: scope)
        // Should include the two project-A notes + the two project-less
        // global notes; project-X stays excluded.
        XCTAssertEqual(merged.count, 4)
        let ids = Set(merged.map(\.id))
        XCTAssertEqual(ids, Set(["g1", "g2", "p1", "p2"]))
        XCTAssertFalse(ids.contains("x1"))
    }

    func testIncludeGlobalNarrowVsWideAreNotEqual() {
        let narrow = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: false
        )
        let wide = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: true
        )
        let n = TogetherLens.merge(notes: fixture(), scope: narrow).map(\.id)
        let w = TogetherLens.merge(notes: fixture(), scope: wide).map(\.id)
        XCTAssertNotEqual(Set(n), Set(w))
        XCTAssertTrue(Set(n).isSubset(of: Set(w)))
    }
}
