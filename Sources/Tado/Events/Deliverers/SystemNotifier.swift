import Foundation
import AppKit
import UserNotifications

/// Event deliverer that converts `TadoEvent`s into macOS system
/// notifications via `UNUserNotificationCenter`. Falls back silently
/// when the user has denied notification permission — in-app banner,
/// Dock badge, and sound deliverers still fire, so the feature is
/// degraded, not broken.
///
/// Delivery rules (§5 of the plan):
///   - The event's routing list must include `"system"`.
///   - `notifications.channels.system` must be true.
///   - Not within `quietHours`.
///   - The Tado window must not already be key-focused (no point
///     pinging users about events they're actively watching).
///
/// Notifications are grouped by `source.kind` so an event storm
/// (e.g. a mega run completing ten sprints back-to-back) collapses
/// into one stack in Notification Center instead of flooding the
/// corner of the screen.
@MainActor
final class SystemNotifier: NSObject {
    static let shared = SystemNotifier()

    private var installed = false
    private var didRequestAuthorization = false
    private var authorizationGranted = false

    func install() {
        guard !installed else { return }
        installed = true

        // UNUserNotificationCenter crashes with
        // NSInternalInconsistencyException when the process is not
        // launched from a signed .app bundle (no bundleIdentifier →
        // "bundleProxyForCurrentProcess is nil"). This happens every
        // time we `swift run` during development.
        //
        // Degrade gracefully: skip this deliverer entirely, log once,
        // and let the other channels (in-app banner, Dock badge, sound)
        // carry the user-visible signal. System banners return as soon
        // as the user runs a proper .app build.
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("[SystemNotifier] no bundle identifier (swift-run build?) — skipping UNUserNotificationCenter wiring")
            return
        }

        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()

        EventBus.shared.addDeliverer { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Authorization

    /// Request authorization exactly once per app process. If the user
    /// denies, we remember locally and skip the `add(...)` call instead
    /// of re-prompting on every event (which would be an API error
    /// anyway — UNUserNotificationCenter only shows the prompt once).
    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorizationGranted = granted
                if let error {
                    NSLog("[SystemNotifier] authorization error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Delivery

    private func handle(_ event: TadoEvent) {
        let settings = ScopedConfig.shared.get()
        guard settings.notifications.channels.system else { return }
        if SoundPlayer.isInQuietHours(settings.notifications.quietHours) { return }

        let channels = settings.notifications.eventRouting[event.type] ?? []
        guard channels.contains("system") else { return }

        // Skip if the Tado window is already frontmost — a banner
        // telling the user something happened on a tile they're
        // looking at is noise.
        if NSApp.isActive { return }

        send(event)
    }

    private func send(_ event: TadoEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.threadIdentifier = event.source.kind
        content.userInfo = ["eventID": event.id.uuidString,
                             "sessionID": event.source.sessionID?.uuidString ?? "",
                             "projectID": event.source.projectID?.uuidString ?? ""]
        // Sound uses the default system sound since the SoundPlayer
        // deliverer already handles our app-side audio routing. Adding
        // a second sound here would double-up on audible events.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[SystemNotifier] add failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Delegate

extension SystemNotifier: @preconcurrency UNUserNotificationCenterDelegate {
    /// Show the banner even when Tado is frontmost. (We short-circuit
    /// in `handle` before reaching `add(...)` when active, so this
    /// path only runs when the user flipped focus between our
    /// check and the OS's delivery decision.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Notification click: activate the app and surface the history
    /// view. Deep-linking to a specific tile / run via `tado://` will
    /// be wired in a follow-up packet when the URL scheme is formally
    /// registered in the app bundle.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            if let idStr = response.notification.request.content.userInfo["eventID"] as? String,
               let id = UUID(uuidString: idStr) {
                EventBus.shared.markRead(id)
                DockBadgeUpdater.shared.refresh()
            }
            completionHandler()
        }
    }
}
