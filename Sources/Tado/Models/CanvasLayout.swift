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
}
