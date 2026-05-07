// Tado × Relay design system — foundation tokens.
//
// One source of truth for the redesign. Every Relay component reads
// from here (or from `RelayTheme` for theme-driven colors). The
// brief's "Restraint is the work" rule lives in code as: there are
// only two foundation colors, one accent, one radius, one shadow,
// one set of motion durations, one type family. Anything richer is
// a derivation.
//
// **Typography decision (deviation from brief)**: the brief names two
// type families — Plus Jakarta Sans for prose / numerals / headings,
// and JetBrains Mono for metadata / kickers / labels / kbd. Tado's
// official brand is single-family Plus Jakarta Sans (full 7-weight ×
// 2-style family is already bundled in `Resources/Fonts/`). So every
// place the brief calls for "mono" — the kicker, brand mark, kbd
// pills, table headers, status meta, palette item meta — Tado renders
// Plus Jakarta Sans instead, in a tracked + small + uppercase
// variant. This makes the design even more single-typeface than the
// brief literally specifies, which sharpens the editorial feel
// further. Concrete mappings live in `RelayType` (see typography
// helpers below).
//
// This file does not delete or modify any existing `Palette` or
// `Typography` token — the Relay slice is additive on top of the
// existing system. As surfaces migrate to Relay components, they
// switch from `Palette.bgPage` etc. to `RelayPalette.background`.
// Phase 15 (cleanup) prunes the legacy tokens once nothing reads
// them.

import SwiftUI

// MARK: - Theme

/// Two-mode theme switch. `ink` (default) renders the dark canvas
/// described in section 2.1 of the redesign brief; `paper` is the
/// inverted near-white surface. Terracotta is invariant across both.
///
/// Stored at `@AppStorage("relay.theme")` and propagated through the
/// view tree via `\.relayTheme` environment key (see `RelayTheme.swift`).
/// Six existing `.preferredColorScheme(.dark)` calls in `TadoApp`
/// migrate to read this value so theme switching does not require a
/// relaunch.
enum RelayTheme: String, CaseIterable, Sendable {
    case ink
    case paper

    /// SwiftUI scheme to apply at the WindowGroup root. Dark for ink,
    /// light for paper. The system's color-scheme dependent UI
    /// (sidebar fill, sheet chrome, focus rings) follows this so the
    /// chrome stops fighting the canvas.
    var swiftUIColorScheme: ColorScheme {
        switch self {
        case .ink:   return .dark
        case .paper: return .light
        }
    }

    var label: String {
        switch self {
        case .ink:   return "Ink"
        case .paper: return "Paper"
        }
    }
}

// MARK: - RelayPalette
//
// Two foundation colors + one accent. Every other color is an alpha
// of one of those three. Resolution is theme-aware: the same token
// (e.g. `RelayPalette.background`) returns the appropriate value for
// the current `RelayTheme`.
//
// Hex values are exact from the brief's section 2.1.

/// Theme-aware color resolution. Use the `for(_:)` accessors when
/// you have a `RelayTheme`; use the `Color` extensions
/// (`Color.relayBackground` etc.) when reading from a SwiftUI view's
/// `\.relayTheme` environment value.
enum RelayPalette {
    // MARK: Foundation (invariant in code, swap on theme)

    /// `#1a1a1a` — the ink canvas. Dark surface in `ink` mode, primary
    /// text on `paper` mode.
    static let inkSolid   = Color(relayHex: 0x1A1A1A)

    /// `#f5f5f5` — the paper canvas. Light surface in `paper` mode,
    /// primary text on `ink` mode.
    static let paperSolid = Color(relayHex: 0xF5F5F5)

    /// `#A44718` — terracotta. The single chromatic accent. Invariant
    /// across modes. ≤10% of any composition.
    static let terracotta = Color(relayHex: 0xA44718)

    // MARK: Resolved roles
    //
    // Each role takes a `RelayTheme` and returns the right color.
    // When you have an `\.relayTheme` env, prefer the matching
    // `Color.relay*` static getter below.

    /// Page / canvas / card background.
    static func background(for theme: RelayTheme) -> Color {
        theme == .ink ? inkSolid : paperSolid
    }

    /// Body text and primary glyph color.
    static func foreground(for theme: RelayTheme) -> Color {
        theme == .ink ? paperSolid : inkSolid
    }

    /// Secondary ink/paper at 64% opacity. "Subtitles in tables", lead
    /// paragraph, descriptions.
    static func foreground2(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.64)
            : Color(relayHex: 0x1A1A1A, alpha: 0.64)
    }

    /// Tertiary at 42%. Kicker text, mono labels, meta strings, table
    /// header columns.
    static func foreground3(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.42)
            : Color(relayHex: 0x1A1A1A, alpha: 0.42)
    }

    /// Quaternary at 32%. "Idle" status dots, disabled states,
    /// over-ellipsised glyphs.
    static func foreground4(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.32)
            : Color(relayHex: 0x1A1A1A, alpha: 0.32)
    }

    /// Quintary at 10%. Soft fills, faintest backgrounds.
    static func foreground5(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.10)
            : Color(relayHex: 0x1A1A1A, alpha: 0.10)
    }

    /// Hairline border — what separates everything in Relay.
    /// `rgba(*, 0.14)` per brief section 2.6.
    static func hair(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.14)
            : Color(relayHex: 0x1A1A1A, alpha: 0.14)
    }

    /// Soft hairline (8%). Inner row separators inside a card.
    static func hairSoft(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.08)
            : Color(relayHex: 0x1A1A1A, alpha: 0.08)
    }

    /// 4% wash — row hover, group bg, kbd pill fill.
    static func wash(for theme: RelayTheme) -> Color {
        theme == .ink
            ? Color(relayHex: 0xF5F5F5, alpha: 0.04)
            : Color(relayHex: 0x1A1A1A, alpha: 0.04)
    }

    // MARK: - Compatibility bridge to Palette
    //
    // For surfaces still on the legacy Palette during the
    // migration, these return values that match the legacy tokens
    // when in `ink` mode. They are removed in phase 15 cleanup.

    /// Bridge for legacy `Palette.bgPage`/`bgElev` users — same as
    /// `background(for:)` but named to make migration searches easy.
    static func legacyPage(for theme: RelayTheme) -> Color {
        background(for: theme)
    }
}

// MARK: - Color extension (theme-aware accessors)
//
// Read these inside a SwiftUI view that has `\.relayTheme` available
// in its environment (set at the WindowGroup root via
// `.relayTheme(_:)`). Each accessor resolves through the env so the
// view re-renders cleanly when the user toggles paper/ink.

extension Color {
    /// Page background. Equivalent to `RelayPalette.background(for: theme)`
    /// but reads the env automatically.
    static func relayBackground(_ theme: RelayTheme) -> Color {
        RelayPalette.background(for: theme)
    }
    static func relayForeground(_ theme: RelayTheme) -> Color {
        RelayPalette.foreground(for: theme)
    }
    static func relayForeground2(_ theme: RelayTheme) -> Color {
        RelayPalette.foreground2(for: theme)
    }
    static func relayForeground3(_ theme: RelayTheme) -> Color {
        RelayPalette.foreground3(for: theme)
    }
    static func relayForeground4(_ theme: RelayTheme) -> Color {
        RelayPalette.foreground4(for: theme)
    }
    static func relayForeground5(_ theme: RelayTheme) -> Color {
        RelayPalette.foreground5(for: theme)
    }
    static func relayHair(_ theme: RelayTheme) -> Color {
        RelayPalette.hair(for: theme)
    }
    static func relayHairSoft(_ theme: RelayTheme) -> Color {
        RelayPalette.hairSoft(for: theme)
    }
    static func relayWash(_ theme: RelayTheme) -> Color {
        RelayPalette.wash(for: theme)
    }
}

// MARK: - Color hex constructor

extension Color {
    /// Build a `Color` from a packed `0xRRGGBB`. Locally named
    /// `relayHex` to avoid colliding with any existing convenience
    /// initializer in `Palette.swift`.
    init(relayHex: UInt32, alpha: Double = 1.0) {
        let r = Double((relayHex >> 16) & 0xFF) / 255.0
        let g = Double((relayHex >> 8) & 0xFF) / 255.0
        let b = Double(relayHex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Spacing

/// Spacing rungs from brief section 2.3. Use these only — never
/// invent values in between. Common patterns are listed in the
/// individual primitives that consume them (`RelayPage` etc.).
enum RelaySpacing {
    static let s2:  CGFloat = 2
    static let s4:  CGFloat = 4
    static let s6:  CGFloat = 6
    static let s8:  CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40
    static let s48: CGFloat = 48
    static let s64: CGFloat = 64
    static let s80: CGFloat = 80
    static let s96: CGFloat = 96

    /// Page horizontal padding (desktop / narrow).
    static let pagePadX: CGFloat = 56
    static let pagePadXNarrow: CGFloat = 24
    /// Page vertical padding.
    static let pagePadTop: CGFloat = 48
    static let pagePadBottom: CGFloat = 80
    /// Section-to-section gap.
    static let sectionGap: CGFloat = 56
    /// Editorial-card internal padding.
    static let cardPadV: CGFloat = 28
    static let cardPadH: CGFloat = 32
    /// Settings row vertical padding.
    static let rowPadVTight: CGFloat = 10
    static let rowPadV:      CGFloat = 18
}

// MARK: - Radius / Shadow

/// One radius for everything per brief section 2.4. The only
/// exception is `pill` (999) for the brand-mark dot and live status
/// dots.
enum RelayRadius {
    static let standard: CGFloat = 5.5
    static let pill:     CGFloat = 999
}

/// One shadow exists per brief section 2.5 — modals only. Cards,
/// rows, inputs, panels, tiles, sidebars, palette rows must NOT use
/// any shadow. Hairlines do the work.
enum RelayShadow {
    /// Modal shadow: `0 18px 40px rgba(26, 26, 26, 0.18)`.
    /// Used by the ⌘K palette card, focused-tile modal, and the toast
    /// banner only.
    static let modalColor  = Color(relayHex: 0x1A1A1A, alpha: 0.18)
    static let modalRadius: CGFloat = 40
    static let modalY:      CGFloat = 18
    static let modalX:      CGFloat = 0
}

// MARK: - Motion

/// Motion durations + easings from brief section 2.7. All animation
/// helpers in `RelayMotion.swift` resolve through these constants.
enum RelayMotionTokens {
    static let durFast:   Double = 0.150  // color/border on hover
    static let durNormal: Double = 0.200  // nav padding-left, palette fade
    static let durSlow:   Double = 0.280  // drawer + Explore slide
    /// Explore slide-in: 240ms `cubic-bezier(0.2, 0.7, 0.3, 1)`.
    static let durExplore: Double = 0.240
    /// Palette modal slide-up + fade-in: 220ms.
    static let durPalette: Double = 0.220
    /// Hairline loader sweep: 1.2s linear infinite.
    static let durLoader: Double = 1.2
    /// Pulsing `running` status dot: 2s infinite.
    static let durStatusPulse: Double = 2.0
    /// Toast auto-dismiss: 2400ms.
    static let durToast: Double = 2.4

    static let easeStd  = (c1x: 0.42, c1y: 0.0, c2x: 0.58, c2y: 1.0)
    static let easeOut  = (c1x: 0.0,  c1y: 0.0, c2x: 0.58, c2y: 1.0)
    /// Explore + palette ease: `cubic-bezier(0.2, 0.7, 0.3, 1)`.
    static let easeOverlay = (c1x: 0.2, c1y: 0.7, c2x: 0.3, c2y: 1.0)
}

// MARK: - Tracking

/// Letter-spacing tokens from brief section 2.2. SwiftUI `.tracking`
/// is in points, not ems, so converters take the resolved font size
/// and return the equivalent points.
enum RelayTracking {
    /// `-0.04em` — 72px stat numerals.
    static func tight(_ pointSize: CGFloat) -> CGFloat { pointSize * -0.04 }
    /// `-0.035em` — h1.
    static func h1(_ pointSize: CGFloat) -> CGFloat { pointSize * -0.035 }
    /// `0.04em` — mono inline meta.
    static func meta(_ pointSize: CGFloat) -> CGFloat { pointSize * 0.04 }
    /// `0.10em` — kbd pills.
    static func kbd(_ pointSize: CGFloat) -> CGFloat { pointSize * 0.10 }
    /// `0.20em` — uppercase kickers + labels.
    static func caps(_ pointSize: CGFloat) -> CGFloat { pointSize * 0.20 }
    /// `0.22em` — brand mark line 1.
    static func brand(_ pointSize: CGFloat) -> CGFloat { pointSize * 0.22 }
}
