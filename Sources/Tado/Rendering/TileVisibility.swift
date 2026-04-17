import CoreGraphics
import Foundation

/// Phase 3 — compute which tiles need a live renderer mounted.
///
/// The visible rect in world (pre-scale) space is
/// `(-offset / scale, viewport / scale)`. A tile with rendered rect
/// `(center ± size/2)` is visible when those rects intersect. A generous
/// margin keeps a tile mounted just beyond the edge so a quick pan
/// doesn't flash the placeholder — users perceive unmount/remount as
/// flicker, so we err on "keep it mounted".
///
/// `TadoCore.Session` keeps running in the background even when the
/// corresponding tile is unmounted — only the `MTKView` + renderer are
/// torn down. Re-mounting is cheap: `TerminalMTKView.init` loads the
/// shader library (Metal caches this after first use) and allocates a
/// per-tile `MTLBuffer`. Order-of-ms.
enum TileVisibility {
    /// Margin applied around the visible rect to keep near-edge tiles
    /// mounted. Measured in world (unscaled) points. One full tile width
    /// of margin means one row of "just-offscreen" tiles stays live.
    static let marginPoints: CGFloat = CanvasLayout.tileWidth

    /// Rectangle that, intersected with a tile's rect, determines
    /// visibility. Returned in world coordinates.
    static func visibleWorldRect(
        viewportSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        guard scale > 0 else {
            return CGRect(origin: .zero, size: viewportSize)
        }
        let worldW = viewportSize.width / scale
        let worldH = viewportSize.height / scale
        let worldX = -offset.width / scale
        let worldY = -offset.height / scale
        return CGRect(x: worldX, y: worldY, width: worldW, height: worldH)
            .insetBy(dx: -marginPoints, dy: -marginPoints)
    }

    /// Tile rect in world coordinates for a session at `canvasPosition`
    /// within a zone offset by `zoneX`. `canvasPosition` is the tile's
    /// CENTER (matches `.position(x:y:)` semantics used in CanvasView).
    static func tileWorldRect(
        canvasCenter: CGPoint,
        zoneX: CGFloat,
        tileWidth: CGFloat,
        tileHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: canvasCenter.x + zoneX - tileWidth / 2,
            y: canvasCenter.y - tileHeight / 2,
            width: tileWidth,
            height: tileHeight
        )
    }

    /// Fast visibility test — returns true when the tile's world rect
    /// intersects the (margined) visible rect.
    static func isVisible(
        tileRect: CGRect,
        visibleRect: CGRect
    ) -> Bool {
        tileRect.intersects(visibleRect)
    }
}
