import SwiftUI

/// First migrated Tado extension. Wraps the existing notification
/// history view in an ``AppExtension`` envelope so it opens as its own
/// window off the sidebar bell instead of as a sheet over the main
/// canvas. The sheet approach stole focus away from the terminal tiles
/// and locked the user out of the canvas; a separate window lets the
/// user keep watching their agents while scrolling event history.
///
/// Behaviour parity with the pre-migration sheet
/// - Same `EventBus.shared.recent` data source.
/// - Same severity-chip + free-text filter bar.
/// - Same context menu (copy title, copy event JSON).
/// - "Mark all read" still calls `EventBus.shared.markAllRead()` + refreshes the dock badge.
///
/// Intentional changes vs the sheet
/// - No explicit "Done" button. Window-level `⌘W` / close-box handles dismissal natively.
/// - `NotificationsWindowView` fills the window instead of a fixed 560x600 sheet frame.
enum NotificationsExtension: AppExtension {
    static let manifest = ExtensionManifest(
        id: "notifications",
        displayName: "Notifications",
        shortDescription: "Event history — filterable log of everything Tado has published since launch.",
        iconSystemName: "bell",
        version: "0.1.0",
        defaultWindowSize: ExtensionManifest.Size(width: 620, height: 640),
        windowResizable: true
    )

    @MainActor @ViewBuilder
    static func makeView() -> AnyView {
        AnyView(NotificationsWindowView())
    }
}
