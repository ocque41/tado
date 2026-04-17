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

    /// Error/destructive. Same hue as accent but more saturated + redder.
    static let danger = Color(hex: 0xC3361A)
    /// Success (muted sage — earthy so it doesn't clash).
    static let success = Color(hex: 0x7A8F5A)
    /// Warning (gold — warmer than yellow to stay in family).
    static let warning = Color(hex: 0xD4A043)
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
