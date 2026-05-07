import Foundation

enum CanvasLayout {
    // Default tile dimensions. The outer `tileWidth/Height` includes
    // padding + title bar; `contentWidth/Height` is the terminal body.
    // At default zoom 0.75 → ~600 visible px → ~70 columns at 13pt mono,
    // enough to fit typical Unix paths without ugly mid-path wrapping.
    // Existing sessions keep their persisted width/height; only new
    // sessions pick up these defaults.
    static let tileWidth: CGFloat = 820
    static let tileHeight: CGFloat = 540
    static let tilePadding: CGFloat = 20
    static let contentWidth: CGFloat = 800
    static let contentHeight: CGFloat = 520

    static func position(forIndex index: Int, gridColumns: Int = 3) -> CGPoint {
        let col = index % gridColumns
        let row = index / gridColumns
        let x = CGFloat(col) * tileWidth + tileWidth / 2
        let y = CGFloat(row) * tileHeight + tileHeight / 2
        return CGPoint(x: x, y: y)
    }

    static func gridLabel(forIndex index: Int, gridColumns: Int = 3) -> String {
        let col = index % gridColumns + 1
        let row = index / gridColumns + 1
        return "[\(col), \(row)]"
    }

    // MARK: - Kanban-mode dispatch placement
    //
    // Lanes for a kanban-mode `DispatchRun`: column 0 hosts the
    // architect tile, columns 1..N host phases by their PhaseJSON
    // `order` field. Each column carries one tile per spawn (a phase
    // is one tile; a re-spawned architect after re-plan stacks under
    // the previous one). The shared header band sits above every
    // column and is rendered once per run by `CanvasView`.

    /// Gutter between adjacent kanban columns. Kept narrower than
    /// `tilePadding` so the tile bodies appear visually grouped
    /// per-column rather than floating in a uniform grid.
    static let kanbanColumnGutter: CGFloat = 24
    /// Total horizontal slot a single column occupies (tile + gutter).
    static let kanbanColumnWidth: CGFloat = tileWidth + kanbanColumnGutter
    /// Header band height for the column-name + phase number row drawn
    /// above every column's tile lane.
    static let kanbanColumnHeaderHeight: CGFloat = 64

    /// Position the centre of a tile inside a kanban column. Y starts
    /// just under the column header band; multiple tiles in the same
    /// column stack downward at `tileHeight` increments.
    static func kanbanPosition(columnIndex: Int, rowInColumn: Int) -> CGPoint {
        let x = CGFloat(columnIndex) * kanbanColumnWidth + tileWidth / 2
        let y = kanbanColumnHeaderHeight
            + CGFloat(rowInColumn) * tileHeight
            + tileHeight / 2
        return CGPoint(x: x, y: y)
    }

    /// World-space X for the centre of a column header. Pairs with
    /// `kanbanPosition` so the lane and its tiles share the same X.
    static func kanbanColumnCenterX(columnIndex: Int) -> CGFloat {
        CGFloat(columnIndex) * kanbanColumnWidth + tileWidth / 2
    }
}
