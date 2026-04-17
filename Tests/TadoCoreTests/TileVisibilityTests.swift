import XCTest
@testable import Tado

/// Unit tests for Phase 3 canvas virtualization math. Pure CGRect/
/// CGPoint logic — no Metal, no PTY, deterministic.
final class TileVisibilityTests: XCTestCase {

    func testVisibleRectAtDefaultTransform() {
        // viewport 1000×600, scale 1, zero offset — visible rect is
        // the viewport with symmetric margin.
        let rect = TileVisibility.visibleWorldRect(
            viewportSize: CGSize(width: 1000, height: 600),
            scale: 1.0,
            offset: .zero
        )
        XCTAssertEqual(rect.origin.x, -TileVisibility.marginPoints)
        XCTAssertEqual(rect.origin.y, -TileVisibility.marginPoints)
        XCTAssertEqual(rect.width, 1000 + 2 * TileVisibility.marginPoints)
        XCTAssertEqual(rect.height, 600 + 2 * TileVisibility.marginPoints)
    }

    func testVisibleRectWithScaleAndOffset() {
        // Half-scale (zoomed out), panned 200 right, 100 down.
        // World = viewport / scale, origin = -offset / scale.
        let rect = TileVisibility.visibleWorldRect(
            viewportSize: CGSize(width: 1000, height: 600),
            scale: 0.5,
            offset: CGSize(width: -200, height: -100)
        )
        XCTAssertEqual(rect.origin.x, 400 - TileVisibility.marginPoints)
        XCTAssertEqual(rect.origin.y, 200 - TileVisibility.marginPoints)
        XCTAssertEqual(rect.width, 2000 + 2 * TileVisibility.marginPoints)
        XCTAssertEqual(rect.height, 1200 + 2 * TileVisibility.marginPoints)
    }

    func testTileAtOriginIsVisibleInDefaultView() {
        let visible = TileVisibility.visibleWorldRect(
            viewportSize: CGSize(width: 1000, height: 600),
            scale: 1.0,
            offset: .zero
        )
        let tile = TileVisibility.tileWorldRect(
            canvasCenter: CGPoint(x: 330, y: 220),
            zoneX: 0,
            tileWidth: 660,
            tileHeight: 440
        )
        XCTAssertTrue(TileVisibility.isVisible(tileRect: tile, visibleRect: visible))
    }

    func testFarOffscreenTileIsNotVisible() {
        let visible = TileVisibility.visibleWorldRect(
            viewportSize: CGSize(width: 1000, height: 600),
            scale: 1.0,
            offset: .zero
        )
        // Tile centered 5000 points to the right — well past the visible
        // rect (which ends at 1000 + margin).
        let tile = TileVisibility.tileWorldRect(
            canvasCenter: CGPoint(x: 5000, y: 220),
            zoneX: 0,
            tileWidth: 660,
            tileHeight: 440
        )
        XCTAssertFalse(TileVisibility.isVisible(tileRect: tile, visibleRect: visible))
    }

    func testNearEdgeTileStaysMountedByMargin() {
        // Tile centered just past the right edge — within the margin
        // buffer, so it remains visible.
        let visible = TileVisibility.visibleWorldRect(
            viewportSize: CGSize(width: 1000, height: 600),
            scale: 1.0,
            offset: .zero
        )
        let justPastEdge = CGPoint(x: 1000 + 50, y: 220)
        let tile = TileVisibility.tileWorldRect(
            canvasCenter: justPastEdge,
            zoneX: 0,
            tileWidth: 660,
            tileHeight: 440
        )
        XCTAssertTrue(TileVisibility.isVisible(tileRect: tile, visibleRect: visible))
    }
}
