// Single-family typography helpers for the Relay redesign.
//
// **Brand decision:** Tado uses Plus Jakarta Sans for everything.
// The Relay brief asks for two families (Jakarta Sans + JetBrains
// Mono); Tado deviates by rendering every "mono" callsite in
// Jakarta Sans with strong tracking + small size + uppercase. This
// keeps the whole app on one type family — a stricter editorial
// vocabulary than the brief literally specifies.
//
// Mono-substitute usage (kicker / brand mark / kbd / table head /
// status meta / palette item meta) is achieved with one of:
//
// - **Caps**: small (9–11px), Medium-or-SemiBold weight, uppercase
//   text, tracking 0.20em. Reads as a "labelly" / metadata-y mark.
// - **Tabular numerals**: digits use `.monospacedDigit()` so columns
//   line up. Combined with caps tracking it gives the same "data"
//   feel JBM would.
// - **Tight scale**: kicker text-10 caps, label text-9 caps,
//   palette meta text-9 caps. Smaller than body so the eye reads it
//   as "supporting metadata" without needing a different family.
//
// Every helper lives here so a future re-introduction of JetBrains
// Mono (if the brand ever absorbs it) is a one-file change.

import SwiftUI

enum RelayType {
    // MARK: - Family

    /// Single registered family name. All helpers below resolve
    /// through this. Fallback chain (handled by `Typography.sans`)
    /// drops to system sans if registration ever fails.
    static let family = "Plus Jakarta Sans"

    // MARK: - Display tier (h1, h2, hero numerals)

    /// Page h1 — display 60pt weight 300 line-height 0.95
    /// tracking -0.035em. Brief section 2.2.
    static func h1(size: CGFloat = 60) -> Font {
        Typography.sans(size: size, weight: .light)
    }

    /// Section h2 — display 32pt weight 300 line-height 1.05.
    /// Smaller than h1, same weight + tone.
    static func h2(size: CGFloat = 32) -> Font {
        Typography.sans(size: size, weight: .light)
    }

    /// Stat numeral — display 72pt weight 300 tracking -0.04em
    /// line-height 0.9. The visual anchor of every page that has a
    /// stat strip.
    static func stat(size: CGFloat = 72) -> Font {
        Typography.sans(size: size, weight: .light)
    }

    /// Modal hero — display 40-44pt at smaller scales for sheet
    /// page anatomy.
    static func modalH1(size: CGFloat = 40) -> Font {
        Typography.sans(size: size, weight: .light)
    }

    // MARK: - Body tier

    /// Lead paragraph — display 15pt line-height 1.6 ink-2 color.
    /// Max-width 64ch enforced at the layout level.
    static func lead(size: CGFloat = 15) -> Font {
        Typography.sans(size: size, weight: .regular)
    }

    /// Body — display 14pt line-height 1.6.
    static func body(size: CGFloat = 14) -> Font {
        Typography.sans(size: size, weight: .regular)
    }

    /// Inline mono value (e.g. tile elapsed time) — Jakarta 18pt
    /// regular with tabular numerals.
    static func inlineValue(size: CGFloat = 18) -> Font {
        Typography.sans(size: size, weight: .regular)
    }

    // MARK: - Mono-substitute tier (caps + tracking)
    //
    // These render Jakarta Sans in a way that semantically
    // substitutes for JBM in the brief: small, tight, uppercase,
    // tracked. Use the resolved tracking helper at the call site
    // because SwiftUI's `Font` doesn't carry tracking.

    /// Kicker — text-10 weight medium uppercase.
    /// Tracking: `RelayTracking.caps(10)` = 2pt.
    static let kicker = Typography.sans(size: 10, weight: .medium)

    /// Brand mark line 1 — text-11 weight 600 uppercase.
    /// Tracking: `RelayTracking.brand(11)` ≈ 2.4pt.
    static let brandMarkLine1 = Typography.sans(size: 11, weight: .semibold)

    /// Brand mark line 2 — text-9 weight regular uppercase.
    /// Tracking: `RelayTracking.caps(9)` = 1.8pt.
    static let brandMarkLine2 = Typography.sans(size: 9, weight: .regular)

    /// Nav item label — text-12 medium. No caps, no tracking;
    /// reads as a clean nav cell. Active state via color, not
    /// weight.
    static let navItem = Typography.sans(size: 12, weight: .medium)

    /// Nav item numeral (the small "01", "02" leading the label).
    /// Text-9 weight medium uppercase. Tracking caps.
    static let navIndex = Typography.sans(size: 9, weight: .medium)

    /// Table column head — text-10 weight semibold uppercase.
    /// Tracking: `RelayTracking.caps(10)` = 2pt.
    static let tableHead = Typography.sans(size: 10, weight: .semibold)

    /// Table cell body — text-13 weight regular.
    static let tableCell = Typography.sans(size: 13, weight: .regular)

    /// Table cell mono-substitute (paths, ids, grid coords). Same
    /// 13pt regular but with `.monospacedDigit()` applied at the
    /// view level. Pair with `.tracking(RelayTracking.meta(13))`
    /// for the "data" feel.
    static let tableCellMeta = Typography.sans(size: 11, weight: .regular)

    /// Status pill text — text-10 weight semibold uppercase
    /// tracking caps.
    static let pill = Typography.sans(size: 10, weight: .semibold)

    /// Inline link — text-11 weight medium. Bottom hairline + arrow
    /// rendered separately. Tracking meta (small +tracking).
    static let inlineLink = Typography.sans(size: 11, weight: .medium)

    /// Kbd pill — text-9 weight medium uppercase. Tracking kbd.
    static let kbd = Typography.sans(size: 9, weight: .medium)

    /// Palette input — text-22 / text-26 weight light tracking
    /// -0.015em. Big editorial input glyph.
    static func paletteInput(size: CGFloat = 22) -> Font {
        Typography.sans(size: size, weight: .light)
    }

    /// Palette item label — text-13 regular.
    static let paletteItem = Typography.sans(size: 13, weight: .regular)

    /// Palette item meta (right side) — text-9 weight semibold
    /// uppercase. Tracking caps.
    static let paletteMeta = Typography.sans(size: 9, weight: .semibold)

    /// Footnote / micro — text-9 weight regular uppercase. Used
    /// in stat block sub-meta and the palette/explore foot.
    static let micro = Typography.sans(size: 9, weight: .regular)
}
