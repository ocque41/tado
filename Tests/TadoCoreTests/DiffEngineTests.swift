import XCTest
@testable import Tado

/// P4 acceptance harness — `DiffEngine` covers the line-granularity
/// diff lens added to User Notes (and reused by Agent Notes in P5).
///
/// Brief criteria:
///   1. Renders insertions/deletions at line granularity on a 2 KB
///      note in ≤ 50 ms.
///   2. Together respects `includeGlobalData` (covered in
///      `TogetherLensTests`).
final class DiffEngineTests: XCTestCase {

    // MARK: - Latency

    func testDiff2KBNoteUnder50ms() {
        // Build a deterministic 2 KB note as ~80 lines of ~25 chars.
        let leftLines = (0..<80).map { i in "line-\(i): the quick brown fox jumps." }
        // Right is identical except every 10th line is rewritten.
        let rightLines: [String] = leftLines.enumerated().map { idx, line in
            idx % 10 == 0 ? "line-\(idx): rewritten content (\(idx)) — slower fox now." : line
        }
        let leftText = leftLines.joined(separator: "\n") + "\n"
        let rightText = rightLines.joined(separator: "\n") + "\n"
        XCTAssertGreaterThanOrEqual(leftText.utf8.count, 2_000)

        // Warm.
        _ = DiffEngine.diff(left: leftText, right: rightText)

        var samples: [Double] = []
        for _ in 0..<10 {
            let t0 = DispatchTime.now()
            let result = DiffEngine.diff(left: leftText, right: rightText)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
            samples.append(ms)
            XCTAssertGreaterThan(result.added, 0)
            XCTAssertGreaterThan(result.removed, 0)
            XCTAssertGreaterThan(result.unchanged, 0)
        }
        let worst = samples.max() ?? 0
        let line = "[DiffEngine] 2KB-ish note · worst-of-10 = \(String(format: "%.2f", worst)) ms\n"
        FileHandle.standardError.write(Data(line.utf8))
        XCTAssertLessThanOrEqual(worst, 50.0, "2 KB diff must run ≤ 50 ms")
    }

    // MARK: - Correctness

    func testIdenticalInputsProduceAllCommon() {
        let text = "alpha\nbeta\ngamma\n"
        let result = DiffEngine.diff(left: text, right: text)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.unchanged, 3)
    }

    func testInsertionsAreMarkedAdded() {
        let result = DiffEngine.diff(left: "a\nb\nc\n", right: "a\nb\nx\nc\n")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(result.lines.contains(where: { $0.origin == .addedOnRight && $0.text == "x" }))
    }

    func testDeletionsAreMarkedRemoved() {
        let result = DiffEngine.diff(left: "a\nb\nc\n", right: "a\nc\n")
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.removed, 1)
        XCTAssertTrue(result.lines.contains(where: { $0.origin == .removedFromLeft && $0.text == "b" }))
    }

    func testEmptyVsContentIsAllAdded() {
        let result = DiffEngine.diff(left: "", right: "first\nsecond\n")
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.unchanged, 0)
    }

    // MARK: - VoiceOver prefix mapping

    func testOriginMarkerGlyphIsStable() {
        XCTAssertEqual(DiffEngine.Origin.common.markerGlyph, " ")
        XCTAssertEqual(DiffEngine.Origin.addedOnRight.markerGlyph, "+")
        XCTAssertEqual(DiffEngine.Origin.removedFromLeft.markerGlyph, "−")
    }

    func testOriginAccessibilityPrefixIsStable() {
        // Both User-Notes and Agent-Notes diff lenses prepend this
        // string to their VoiceOver row label. Pin the contract here
        // so renaming "Added:" → something else has to update both
        // surfaces consciously.
        XCTAssertEqual(DiffEngine.Origin.common.accessibilityPrefix, "Unchanged:")
        XCTAssertEqual(DiffEngine.Origin.addedOnRight.accessibilityPrefix, "Added:")
        XCTAssertEqual(DiffEngine.Origin.removedFromLeft.accessibilityPrefix, "Removed:")
    }

    func testReplacementShowsPairedRemoveThenAdd() {
        // "b" → "B": expect a deletion and an insertion (LCS picks
        // either order; we just check both events appear).
        let result = DiffEngine.diff(left: "a\nb\nc\n", right: "a\nB\nc\n")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.unchanged, 2)
    }
}
