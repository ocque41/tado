// Aligned to /Users/miguel/Documents/cumulus/CUMULUS-BRAND.md v1.0
//
// The master Cumulus brand is monochrome ink-on-paper plus a single
// chromatic moment (terracotta `#A44718`). Status hues (sage success,
// gold warning, separate green) are deprecated — they collapse to
// ink-tiers per the master spec ("Status colors — collapsed"). The
// only chromatic exception is destructive confirmation, which keeps
// terracotta as the alert/destructive accent.
//
// Deprecated tokens (`success`, `warning`, `green`, `greenSoft`)
// remain as `let` aliases so every existing call site continues to
// compile, but their underlying values now resolve to ink-tiers
// (or terracotta for `danger`). Refer to per-token comments below.

import SwiftUI
import AppKit

/// Tado's design palette. All UI chrome (sidebars, buttons, headers, form
/// controls) reads colors from this one place so a theme swap is a single
/// edit. The canvas + terminal grids still use `TerminalTheme` — they
/// have their own concept of color (per-tile bg/fg, 16-slot ANSI).
///
/// Three anchor colors, picked to read as "neutral dark + ember":
///
/// - `background` `#1A1A1A`  — neutral dark. Sidebar + window.
/// - `foreground` `#F5F5F5`  — near-white (neutral). Primary text.
/// - `accent`     `#A44718`  — burnt sienna. Focus rings, progress, links.
///
/// Every surface below is a pure neutral grey (equal R/G/B channels) so
/// the only chromatic element in the UI is the burnt-sienna accent.
///
/// The **body** stack is intentionally flat: `background`, `canvas`,
/// and `surface` all resolve to the same `#1A1A1A`. The canvas, every
/// page body, the Settings sheet, and all scroll content read as a
/// single unbroken neutral.
///
/// `surfaceElevated` (`#2A2A2A`) is the raised tier — used for every
/// place the UI needs a fill delta to communicate structure:
/// - **Page headers** (Todos / Projects / Teams / Dispatch modal
///   top+footer bars / Sidebar "Sessions" strip) — a raised strip
///   anchors the top of each page above the flat body.
/// - **Tile titlebars** in the canvas.
/// - **List-section headers** inside scroll content.
/// - **Small action pills** where the fill contrast IS the affordance
///   cue ("this chip is clickable"). When a pill sits inside a raised
///   header it instead uses `surface` (flat `#1A1A1A`) so it reads as
///   an inset against the elevated strip.
///
/// Text tiers use the neutral foreground at varying alphas — when
/// composited on the neutral backdrop they render as true greys, no
/// hue bleed.
enum Palette {
    // MARK: Anchors

    /// Neutral dark — window + page + canvas background. All flat.
    static let background = Color(hex: 0x1A1A1A)
    /// Near-white neutral — primary text + active icon.
    static let foreground = Color(hex: 0xF5F5F5)
    /// Burnt sienna — focus rings, primary-button fill, active tab pill.
    static let accent = Color(hex: 0xA44718)

    // MARK: Surfaces

    /// Alias for `background` — kept as a distinct token so view code
    /// can still express intent ("this is a raised strip, even though
    /// the fill matches the page") and a future design pass can split
    /// them again without a rename.
    static let surface = Color(hex: 0x1A1A1A)
    /// The one surface that stays slightly raised — `#2A2A2A`. Used by
    /// tile titlebars, list-section headers, and pill buttons where
    /// the fill delta is the affordance cue.
    static let surfaceElevated = Color(hex: 0x2A2A2A)
    /// Canvas background — flat with the window. Tiles are delineated
    /// by their 1px divider border, not by a canvas/tile fill contrast.
    static let canvas = Color(hex: 0x1A1A1A)
    /// Raised surface when focused/selected. Just the accent at 12%.
    static let surfaceAccent = Color(hex: 0xA44718, alpha: 0.12)
    /// Soft accent wash for form "edit mode" strips — matches surfaceAccent
    /// but at a lighter alpha so it reads as a highlight, not a button.
    static let surfaceAccentSoft = Color(hex: 0xA44718, alpha: 0.04)
    /// Subtle divider line between panels.
    static let divider = Color(hex: 0xF5F5F5, alpha: 0.08)

    // MARK: Text tiers

    /// Body text, labels. Pure neutral white (245/245/245).
    static let textPrimary = foreground
    /// Secondary text — help copy, descriptions, captions.
    /// Near-white at 65% alpha; composites to pure grey on neutral
    /// backgrounds with no hue tint.
    static let textSecondary = Color(hex: 0xF5F5F5, alpha: 0.65)
    /// Disabled text / placeholders.
    static let textTertiary = Color(hex: 0xF5F5F5, alpha: 0.35)
    /// Text colored by the accent (links, badges).
    static let textAccent = accent

    // MARK: Interactive states

    /// Hover background for plain buttons / list rows.
    static let hoverBackground = Color(hex: 0xF5F5F5, alpha: 0.05)
    /// Pressed/active state.
    static let pressedBackground = Color(hex: 0xF5F5F5, alpha: 0.10)
    /// Focus ring around text fields + buttons.
    static let focusRing = accent

    // MARK: Status
    //
    // Per the master brand spec (CUMULUS-BRAND.md "Status colors —
    // collapsed"): only destructive uses chromatic terracotta; every
    // other historical status hue (sage success, gold warning, separate
    // green) collapses to ink-tiers. The aliases below are kept so
    // existing call sites continue to compile, but their values now
    // resolve to terracotta + neutral ink.

    /// Destructive accent — terracotta `#A44718`. The single
    /// chromatic exception per the master brand. Was `#C3361A` (a
    /// redder variant); collapsed to the canonical brand terracotta
    /// so destructive UI lands on the same hue as the accent.
    static let danger = Color(hex: 0xA44718)
    /// DEPRECATED — collapsed to ink per CUMULUS-BRAND.md.
    /// Was muted sage; now resolves to the secondary ink tier so
    /// "success" reads as a neutral (positive) state without a hue.
    static let success = Color(hex: 0xF5F5F8, alpha: 0.64)
    /// DEPRECATED — collapsed to ink per CUMULUS-BRAND.md.
    /// Was warm gold; now resolves to the tertiary ink tier so
    /// "warning" reads as a slightly subdued neutral. For genuinely
    /// dangerous warnings, use `Palette.danger` (terracotta).
    static let warning = Color(hex: 0xF5F5F8, alpha: 0.42)

    // MARK: - Grid design system (v0.18 design pass)
    //
    // The "Projects Page" design pass added a structural grid + tabular-row
    // visual language across Projects/Todos/Extensions. The tokens below
    // map to that design's `oklch(...)` palette — cool deep neutrals with
    // a tight 5-step elevation ramp (page → elevated → row → row-hi),
    // a 4-tier ink scale, and explicit `rule` / `ruleStrong` hairlines
    // for the per-cell vertical separators that make the table readable
    // without alternating-row fills.
    //
    // These are additive; the legacy tokens above (`background`,
    // `surface`, `surfaceElevated`, `divider`, `textPrimary` etc.) still
    // drive the canvas, sidebar, settings, and modal chrome. New views
    // reference `bgPage` / `bgElev` / `rule` / `ink` etc. so the two
    // systems coexist cleanly during the migration.
    //
    // Colour values are sRGB hex approximations of the source oklch
    // values — close enough on a calibrated display that the structural
    // intent is preserved; SwiftUI's Color does not yet expose oklch
    // natively as of macOS 14, so the conversion is a one-time cost.

    /// Page background — `oklch(0.18 0.005 250)`. Deepest neutral in
    /// the ramp; the canvas of every page that uses the new design.
    static let bgPage = Color(hex: 0x1B1C1F)
    /// Elevated surface — `oklch(0.215 0.006 250)`. Topbar fill, run
    /// rows, composer body, every "card" that needs a one-step lift
    /// off the page.
    static let bgElev = Color(hex: 0x252628)
    /// Row fill (table cells, inactive composer chrome).
    static let bgRow = Color(hex: 0x2A2B2D)
    /// Row hover / active state fill.
    static let bgRowHi = Color(hex: 0x313234)

    /// Hairline rules. Vertical cell dividers, section bottoms.
    static let rule = Color(hex: 0x3A3B3D)
    /// Stronger rule for hovered borders / focused inputs.
    static let ruleStrong = Color(hex: 0x48494B)

    /// 4-tier ink scale. `ink` is primary, descends to `ink4` (uppercase
    /// labels, micro metadata). Distinct from the legacy
    /// `textPrimary/Secondary/Tertiary` so the new structural type
    /// hierarchy can render correctly without affecting sidebar copy.
    static let ink  = Color(hex: 0xF5F5F8)
    static let ink2 = Color(hex: 0xB6B7BA)
    static let ink3 = Color(hex: 0x7E7F82)
    static let ink4 = Color(hex: 0x56575A)

    /// Soft accent paired tokens — used by `pill-planning`, accent
    /// outline buttons, and subtle accent washes. The accent itself
    /// is the existing `accent` token (warm amber), so the design's
    /// "single hue" rule is still honoured.
    static let accentSoft = Color(hex: 0x8A4A20)
    static let accentBg   = Color(hex: 0x3D2616, alpha: 0.55)

    /// DEPRECATED — collapsed to ink per CUMULUS-BRAND.md.
    /// Was a brighter green for `pill-running` + the user chip's
    /// live dot; now resolves to the secondary ink tier so the dot
    /// and pill read as a neutral "live" state. The brand mark dot
    /// in the top nav is the one place where chromatic terracotta
    /// appears in the chrome.
    static let green     = Color(hex: 0xF5F5F8, alpha: 0.64)
    /// DEPRECATED — collapsed to ink per CUMULUS-BRAND.md. Border
    /// companion to `green` above. Now resolves to the standard
    /// hairline rule so soft green outlines fade into the divider
    /// vocabulary.
    static let greenSoft = Color(hex: 0x3A3B3D)
}

// MARK: - NSColor bridge (for non-SwiftUI call sites)

extension Palette {
    /// AppKit bridge. Views that need `NSColor` (NSTextField fg, NSView
    /// layer bg, Metal clear-color conversion) read from here so the
    /// palette single-source stays intact.
    enum NS {
        static let background = Palette.background.nsColor
        static let foreground = Palette.foreground.nsColor
        static let accent = Palette.accent.nsColor
        static let surface = Palette.surface.nsColor
        static let surfaceElevated = Palette.surfaceElevated.nsColor
        static let canvas = Palette.canvas.nsColor
    }
}

// MARK: - Color convenience

extension Color {
    /// Build a `Color` from a packed 24-bit RGB hex (`0xRRGGBB`).
    /// sRGB space so it matches the Metal renderer's cell colors.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// `NSColor` of the same `Color`, used when an AppKit API needs it.
    /// The back-converter is not perfect for non-sRGB display spaces on
    /// some monitors; these three anchors are sRGB though, so round-trip
    /// losslessly.
    var nsColor: NSColor {
        NSColor(self)
    }
}
