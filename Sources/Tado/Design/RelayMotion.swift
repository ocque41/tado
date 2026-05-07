// Reduced-motion-aware animation helpers.
//
// Every Relay animation reads through these helpers so a single
// branch on `\.accessibilityReduceMotion` degrades motion to
// instant transitions for the user who has macOS Reduce Motion
// enabled. Pulsing status dots, slide-ins, palette rises — all
// gated.
//
// Call sites use `RelayAnim.standard(reduce:)` etc. to receive an
// `Animation?` (nil when reduced) which composes naturally with
// `withAnimation(...)` / `.animation(...)`.

import SwiftUI

enum RelayAnim {
    /// Standard ease (CSS `cubic-bezier(0.42, 0, 0.58, 1)`).
    /// Used for color/border on hover, palette fade.
    static func standard(reduce: Bool, dur: Double = RelayMotionTokens.durFast) -> Animation? {
        guard !reduce else { return nil }
        let e = RelayMotionTokens.easeStd
        return .timingCurve(e.c1x, e.c1y, e.c2x, e.c2y, duration: dur)
    }

    /// Ease-out — faster decel, used for nav padding-left etc.
    static func easeOut(reduce: Bool, dur: Double = RelayMotionTokens.durNormal) -> Animation? {
        guard !reduce else { return nil }
        let e = RelayMotionTokens.easeOut
        return .timingCurve(e.c1x, e.c1y, e.c2x, e.c2y, duration: dur)
    }

    /// Overlay slide-in (Explore + palette rise). The brief's
    /// `cubic-bezier(0.2, 0.7, 0.3, 1)` for snappy entrance.
    static func overlay(reduce: Bool, dur: Double = RelayMotionTokens.durExplore) -> Animation? {
        guard !reduce else { return nil }
        let e = RelayMotionTokens.easeOverlay
        return .timingCurve(e.c1x, e.c1y, e.c2x, e.c2y, duration: dur)
    }

    /// Drawer slide (the slow 280ms variant).
    static func drawer(reduce: Bool) -> Animation? {
        standard(reduce: reduce, dur: RelayMotionTokens.durSlow)
    }
}
