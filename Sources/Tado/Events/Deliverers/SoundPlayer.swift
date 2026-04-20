import Foundation
import AppKit

/// Event deliverer that plays a short `NSSound` per event, guided by
/// three inputs:
///
///   1. The event's routing entry in `global.json`'s
///      `notifications.eventRouting[type]`. If `"sound"` is not in the
///      list, the event is silent for this deliverer.
///   2. `notifications.channels.sound`. If false, all sounds are
///      globally muted (a "shut up" toggle for focus mode).
///   3. `notifications.quietHours`. If within the window, sounds are
///      suppressed regardless of routing (the user explicitly asked
///      for silence during this block).
///
/// Separately, `terminal.bell` honors `ui.bellMode` — the same enum
/// the Metal renderer used to consume directly. `.off` → silent,
/// `.audible` / `.both` → NSSound.beep, `.visual` → silent (visual
/// flash is handled in the tile view, not here).
///
/// All sound lookups are cached; a missing system sound falls back to
/// `NSSound.beep()` so the user still gets an audible cue.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    /// Install on the shared bus. Idempotent in practice because
    /// `TadoApp.init()` only runs once, but we guard anyway so hot
    /// reload in dev doesn't double-subscribe.
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        EventBus.shared.addDeliverer { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Delivery

    private func handle(_ event: TadoEvent) {
        let settings = ScopedConfig.shared.get()

        // Global "all sounds off" takes precedence.
        guard settings.notifications.channels.sound else { return }

        // Quiet hours — clamp to minute resolution; "now" HH:MM falls
        // inside a window that may wrap midnight (22:00 → 08:00).
        if Self.isInQuietHours(settings.notifications.quietHours) { return }

        // Bell is special-cased: BEL mutes live outside event routing,
        // under `ui.bellMode`, because that's what users have been
        // conditioned to configure since macOS Terminal.app shipped.
        if event.type == "terminal.bell" {
            playBell(mode: settings.ui.bellMode)
            return
        }

        // Everything else: routing table is authoritative.
        let channels = settings.notifications.eventRouting[event.type] ?? []
        guard channels.contains("sound") else { return }

        playSound(for: event)
    }

    // MARK: - Sound selection

    private func playBell(mode: String) {
        switch mode {
        case "off":           break
        case "visual":        break
        case "audible", "both": NSSound.beep()
        default:              NSSound.beep()
        }
    }

    /// Map an event severity to a built-in system sound. Picked so the
    /// severities are audibly distinct:
    /// - success → Glass (bright, rising)
    /// - warning → Funk   (neutral, attention-grabbing)
    /// - error   → Basso  (low, negative)
    /// - info    → Tink   (very short tick)
    private func playSound(for event: TadoEvent) {
        let name: String
        switch event.severity {
        case .success: name = "Glass"
        case .warning: name = "Funk"
        case .error:   name = "Basso"
        case .info:    name = "Tink"
        }
        if let s = NSSound(named: NSSound.Name(name)) {
            s.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Quiet hours

    static func isInQuietHours(_ qh: GlobalSettings.QuietHours) -> Bool {
        guard qh.enabled else { return false }
        guard let from = parseHHMM(qh.from), let to = parseHHMM(qh.to) else { return false }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let nowMin = (now.hour ?? 0) * 60 + (now.minute ?? 0)

        if from == to { return true } // degenerate → always quiet
        if from < to {
            // Same-day window: e.g. 13:00 → 17:00
            return nowMin >= from && nowMin < to
        } else {
            // Wraps midnight: e.g. 22:00 → 08:00
            return nowMin >= from || nowMin < to
        }
    }

    private static func parseHHMM(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}
