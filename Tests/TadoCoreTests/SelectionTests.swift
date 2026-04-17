import XCTest
@testable import Tado

/// Unit tests for Phase 2.11 selection text extraction. Pure grid math —
/// no Metal, no PTY. Feeds synthetic snapshots constructed via
/// `TadoCore.Snapshot.synthetic` and asserts the extractor returns the
/// right String for each common selection shape.
final class SelectionExtractorTests: XCTestCase {
    /// Build a 10-col × 3-row grid filled with the given rows (space-padded
    /// to 10 chars each).
    private func snapshot(rows: [String]) -> TadoCore.Snapshot {
        precondition(rows.count == 3)
        let padded: [String] = rows.map { row in
            let trimmed = String(row.prefix(10))
            return trimmed + String(repeating: " ", count: max(0, 10 - trimmed.count))
        }
        let chars: [[Character]] = padded.map { Array($0) }
        return TadoCore.Snapshot.synthetic(cols: 10, rows: 3) { col, row in
            let ch = chars[row][col]
            let scalar = ch.unicodeScalars.first?.value ?? 32
            return TadoCore.Cell(
                ch: UInt32(scalar),
                fg: 0xFFFFFFFF,
                bg: 0x000000FF,
                attrs: 0
            )
        }
    }

    func testSingleRowSelectionExtractsInclusiveRange() {
        let snap = snapshot(rows: ["hello world", "second row", "third row "])
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 0, row: 0),
            end:   CellCoord(col: 4, row: 0)
        )
        XCTAssertEqual(got, "hello")
    }

    func testMultiRowSelectionIncludesMiddleRowsFullWidth() {
        let snap = snapshot(rows: ["hello", "middle", "third"])
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 3, row: 0),
            end:   CellCoord(col: 2, row: 2)
        )
        // Row 0 from col 3 → "lo" (rest trimmed since "hello" is 5 chars)
        // Row 1 full width → "middle"
        // Row 2 up to col 2 → "thi"
        XCTAssertEqual(got, "lo\nmiddle\nthi")
    }

    func testTrailingSpacesAreTrimmedPerRow() {
        let snap = snapshot(rows: ["abc       ", "xyz", ""])
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 0, row: 0),
            end:   CellCoord(col: 9, row: 0)
        )
        XCTAssertEqual(got, "abc")
    }

    func testEmptyGridSelectionReturnsBlankLines() {
        let snap = snapshot(rows: ["", "", ""])
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 0, row: 0),
            end:   CellCoord(col: 9, row: 2)
        )
        XCTAssertEqual(got, "\n\n")
    }

    func testWideCharFillerCellIsSkippedInExtract() {
        // Build a row containing a wide CJK char "中" (U+4E2D) followed
        // by "ok". `中` occupies cols 0..1; the cell at col 1 is a
        // WIDE_FILLER. The extractor must return "中ok", not "中 ok"
        // (which would be the naive space-pad result).
        let wide: UInt32 = 0x4E2D
        let snap = TadoCore.Snapshot.synthetic(cols: 10, rows: 1) { col, _ in
            switch col {
            case 0: return TadoCore.Cell(
                ch: wide,
                fg: 0xFFFFFFFF, bg: 0x000000FF,
                attrs: MetalTerminalRenderer.Attr.wide
            )
            case 1: return TadoCore.Cell(
                ch: 0,
                fg: 0xFFFFFFFF, bg: 0x000000FF,
                attrs: MetalTerminalRenderer.Attr.wideFiller
            )
            case 2: return TadoCore.Cell(ch: UInt32("o".unicodeScalars.first!.value),
                                         fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            case 3: return TadoCore.Cell(ch: UInt32("k".unicodeScalars.first!.value),
                                         fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            default: return TadoCore.Cell(ch: 0, fg: 0xFFFFFFFF, bg: 0x000000FF, attrs: 0)
            }
        }
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 0, row: 0),
            end:   CellCoord(col: 9, row: 0)
        )
        XCTAssertEqual(got, "中ok")
    }

    func testZeroWidthSelectionOnEmptyRow() {
        let snap = snapshot(rows: ["foo", "", "bar"])
        let got = TerminalTextExtractor.extract(
            from: snap,
            start: CellCoord(col: 5, row: 1),
            end:   CellCoord(col: 5, row: 1)
        )
        XCTAssertEqual(got, "")
    }
}
