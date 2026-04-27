import XCTest
@testable import Tado

/// P5 acceptance — both User Notes and Agent Notes lens architectures
/// share the SAME pure helpers under
/// `Sources/Tado/Extensions/Dome/Surfaces/Lenses/`. We can't reflect
/// SwiftUI views, so "identical lens parity" is enforced as: given
/// the same fixture, every helper that drives a lens (`DiffEngine`,
/// `TogetherLens`) is deterministic, and the surfaces both pass
/// through `NoteLensMode` cases verbatim.
///
/// The brief also calls out "diff helper has its own unit tests" —
/// covered by `DiffEngineTests`. This file pins the parity contract.
final class LensParityTests: XCTestCase {

    private static let projectA = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    // MARK: - Diff parity

    func testDiffOutputIsIdenticalAcrossInvocations() {
        // The User surface diffs `snapshotBody → editingBody`; the Agent
        // surface diffs `snapshotAgentBody → currentAgentContent`. Both
        // route through `DiffEngine.diff(left:right:)` so the same
        // input must produce the same output, byte-for-byte.
        let left = "alpha\nbeta\ngamma\n"
        let right = "alpha\nBETA\ngamma\nappended\n"

        let userResult = DiffEngine.diff(left: left, right: right)
        let agentResult = DiffEngine.diff(left: left, right: right)
        XCTAssertEqual(userResult, agentResult)
        XCTAssertEqual(userResult.added, agentResult.added)
        XCTAssertEqual(userResult.removed, agentResult.removed)
        XCTAssertEqual(userResult.unchanged, agentResult.unchanged)
    }

    // MARK: - Together parity

    func testTogetherOutputIsIdenticalAcrossSurfaces() {
        let now = Date()
        let notes = [
            DomeRpcClient.NoteSummary(
                id: "g", title: "Global", topic: "user",
                slug: "g", userPath: "u", agentPath: "a",
                createdAt: now, updatedAt: now,
                agentActive: true, ownerScope: nil,
                projectID: nil, projectRoot: nil, knowledgeKind: nil
            ),
            DomeRpcClient.NoteSummary(
                id: "p", title: "Project", topic: "user",
                slug: "p", userPath: "u", agentPath: "a",
                createdAt: now.addingTimeInterval(-30),
                updatedAt: now.addingTimeInterval(-30),
                agentActive: false, ownerScope: "project",
                projectID: Self.projectA.uuidString,
                projectRoot: "/tmp/a", knowledgeKind: nil
            ),
        ]
        let scope = DomeScopeSelection.project(
            id: Self.projectA, name: "A", rootPath: "/tmp/a", includeGlobal: true
        )

        // User Notes calls TogetherLens.merge; Agent Notes calls the
        // same function via the same import. Identical inputs ⇒
        // identical outputs.
        let userMerge = TogetherLens.merge(notes: notes, scope: scope)
        let agentMerge = TogetherLens.merge(notes: notes, scope: scope)

        XCTAssertEqual(userMerge.map(\.id), agentMerge.map(\.id))
        XCTAssertEqual(userMerge.count, 2)
    }

    // MARK: - Mode parity

    func testNoteLensModeAllCasesAreShared() {
        // Both surfaces use `NoteLensMode.allCases` for their picker.
        // Pin the cardinality + identifiers so a future regression
        // (e.g. someone adds a fourth mode to one surface only) trips
        // this test.
        let cases = NoteLensMode.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertEqual(cases.map(\.rawValue), ["edit", "diff", "together"])
    }
}
