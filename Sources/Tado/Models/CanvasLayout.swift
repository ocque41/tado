import Foundation

enum CanvasLayout {
    static let tileWidth: CGFloat = 660
    static let tileHeight: CGFloat = 440
    static let tilePadding: CGFloat = 20
    static let contentWidth: CGFloat = 640
    static let contentHeight: CGFloat = 420

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
