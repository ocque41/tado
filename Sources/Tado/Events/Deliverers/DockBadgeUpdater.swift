import Foundation
import AppKit

/// Mirrors `EventBus.shared.unreadCount` into `NSApp.dockTile.badgeLabel`.
/// The badge clears automatically when the user focuses the Tado
/// window (NSApplication.didBecomeActiveNotification) because at that
/// point the user has seen the banners and the sidebar bell glyph is
/// in their peripheral vision.
///
/// Gated by `notifications.channels.dockBadge` — users who dislike
/// Dock badges can flip it off in Settings and keep banners / sounds.
@MainActor
final class DockBadgeUpdater {
    static let shared = DockBadgeUpdater()

    private var installed = false
    private var activationObserver: NSObjectProtocol?

    func install() {
        guard !installed else { return }
        installed = true

        EventBus.shared.addDeliverer { [weak self] _ in
            self?.refresh()
        }

        // Clear on focus: once the user actively returns to Tado, the
        // "you have unread events" signal has served its purpose.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                EventBus.shared.markAllRead()
                DockBadgeUpdater.shared.refresh()
            }
        }
    }

    /// Write (or clear) the badge label. Called after every event and
    /// after "mark all read" on window focus.
    func refresh() {
        let settings = ScopedConfig.shared.get()
        let unread = EventBus.shared.unreadCount

        let label: String?
        if !settings.notifications.channels.dockBadge || unread == 0 {
            label = nil
        } else if unread > 99 {
            label = "99+"
        } else {
            label = String(unread)
        }
        NSApp.dockTile.badgeLabel = label
    }

    deinit {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
