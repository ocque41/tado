import SwiftUI

/// Per-window zoom level for the browser-style app-wide zoom feature.
///
/// One instance lives at the root of each `WindowGroup` (main + each
/// extension), so windows zoom independently. The current value is the
/// scale factor applied via `scaleEffect` on the wrapped content; values
/// above 1.0 enlarge, below 1.0 shrink.
@Observable
@MainActor
final class WindowZoomState {
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 3.0
    static let stepFactor: CGFloat = 1.12

    var zoom: CGFloat = 1.0

    func zoomIn() {
        zoom = min(WindowZoomState.maxZoom, zoom * WindowZoomState.stepFactor)
    }

    func zoomOut() {
        zoom = max(WindowZoomState.minZoom, zoom / WindowZoomState.stepFactor)
    }

    func reset() {
        zoom = 1.0
    }
}
