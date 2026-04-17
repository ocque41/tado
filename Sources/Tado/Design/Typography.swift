import SwiftUI
import AppKit
import CoreText

/// Tado's typography system — one place that names every font size/weight
/// the app uses. Views call `Typography.title` instead of repeating
/// `.system(size: 16, weight: .semibold)` inline, so re-tuning the scale
/// is a single edit.
///
/// The primary family is **Plus Jakarta Sans** (bundled in
/// `Resources/Fonts`, registered at app start by
/// `Typography.registerFonts()`). Terminal cells keep SF Mono — a
/// proportional sans can't drive a fixed-cell grid.
///
/// # Scale philosophy
///
/// Jakarta Sans ships **seven upright weights** (ExtraLight 200, Light 300,
/// Regular 400, Medium 500, SemiBold 600, Bold 700, ExtraBold 800) plus
/// matching italics. The catalog below exercises every weight, so any
/// future UI that wants a thinner hero or a heavier badge has a token
/// waiting instead of a one-off `.system(...)` call.
///
/// Roles descend in roughly 1.2× steps so a heading reads clearly bigger
/// than body copy without needing a full 2× jump. This is a utility app
/// that lives in a small window, not a marketing site — the scale is
/// compact, 9pt → 32pt.
///
/// # Tier map (sans)
///
/// ```
/// tier        size  weight         role
/// ──────────  ────  ─────────────  ─────────────────────────────
/// hero        32    ExtraBold      ultra-heavy hero (rare)
/// heroThin    32    ExtraLight     ultra-thin editorial hero
/// displayXL   28    Bold           large hero
/// display     22    Bold           sheet hero
/// displaySm   18    SemiBold       modal hero
/// titleLg     20    Bold           large view title
/// title       16    SemiBold       standard view title
/// titleSm     14    SemiBold       nested / inline title
/// headingLg   14    SemiBold       big section header
/// heading     13    SemiBold       form section header
/// headingSm   12    SemiBold       sub-section
/// labelLg     13    Medium         primary button label
/// label       12    Medium         standard form label
/// labelSm     11    Medium         tight form label
/// bodyLg      13    Regular        emphasized body
/// body        12    Regular        standard body / help copy
/// bodyEmph    12    Medium         emphasized body
/// bodyBold    12    SemiBold       stressed body
/// bodyItalic  12    Regular italic quote / stress
/// bodyLight   12    Light          tertiary editorial
/// bodySm      11    Regular        small body
/// calloutLg   12    Medium         large chip
/// callout     11    Medium         standard chip / metadata
/// calloutBold 11    SemiBold       emphasized chip
/// calloutItal 11    Medium italic  italic chip
/// caption     11    Regular        footnote / secondary
/// captionEmph 11    Medium         emphasized caption
/// captionBold 11    SemiBold       attention caption
/// captionItal 11    Regular italic italic caption
/// captionSm   10    Regular        tiny caption
/// micro       10    Regular        dense metadata
/// microEmph   10    Medium         emphasized metadata
/// microBold   10    Bold           badge / count pill
/// microItal   10    Regular italic italic metadata
/// overlineLg  11    Bold           big overline (callers add tracking)
/// overline    10    SemiBold       overline  (callers add tracking)
/// ```
///
/// # Tier map (mono — SF Mono)
///
/// Monospace variants reserved for things that are *data*: todo text,
/// paths, grid coords, keyboard hints, agent ids. UI chrome reads as
/// Jakarta Sans; only the data sitting inside the chrome reads as code.
enum Typography {
    // MARK: Family

    /// PostScript family name registered from the bundled TTFs.
    /// `NSFont(name:size:)` returns nil for any weight we haven't
    /// registered, so the helpers below fall back to the matching
    /// system weight — defense against a missing file in a dev build.
    static let family = "Plus Jakarta Sans"

    // MARK: Hero / display tier

    /// Ultra-heavy 32pt ExtraBold — reserved for one-off hero moments
    /// (onboarding, first-run). Exercises the ExtraBold weight.
    static let hero       = sans(size: 32, weight: .heavy)
    /// Ultra-thin 32pt ExtraLight — rare editorial hero. Exercises the
    /// ExtraLight weight.
    static let heroThin   = sans(size: 32, weight: .ultraLight)
    /// 28pt Bold — large display, used when `display` isn't loud enough.
    static let displayXL  = sans(size: 28, weight: .bold)
    /// 22pt Bold — sheet / page hero.
    static let display    = sans(size: 22, weight: .bold)
    /// 18pt SemiBold — modal hero, tighter than `display`.
    static let displaySm  = sans(size: 18, weight: .semibold)

    // MARK: Title tier (window / sheet / view titles)

    static let titleLg    = sans(size: 20, weight: .bold)
    static let title      = sans(size: 16, weight: .semibold)
    static let titleSm    = sans(size: 14, weight: .semibold)

    // MARK: Heading tier (section / group headers inside forms)

    static let headingLg  = sans(size: 14, weight: .semibold)
    static let heading    = sans(size: 13, weight: .semibold)
    static let headingSm  = sans(size: 12, weight: .semibold)

    // MARK: Label tier (form controls, prominent UI strings)

    static let labelLg    = sans(size: 13, weight: .medium)
    static let label      = sans(size: 12, weight: .medium)
    static let labelSm    = sans(size: 11, weight: .medium)

    // MARK: Body tier (paragraphs, help copy, descriptions)

    static let bodyLg         = sans(size: 13, weight: .regular)
    static let body           = sans(size: 12, weight: .regular)
    static let bodyEmphasis   = sans(size: 12, weight: .medium)
    static let bodyBold       = sans(size: 12, weight: .semibold)
    static let bodyItalic     = sans(size: 12, weight: .regular, italic: true)
    /// 12pt Light — tertiary editorial copy. Exercises the Light weight.
    static let bodyLight      = sans(size: 12, weight: .light)
    static let bodySm         = sans(size: 11, weight: .regular)

    // MARK: Callout tier (status chips, inline metadata)

    static let calloutLg      = sans(size: 12, weight: .medium)
    static let callout        = sans(size: 11, weight: .medium)
    static let calloutBold    = sans(size: 11, weight: .semibold)
    static let calloutItalic  = sans(size: 11, weight: .medium, italic: true)

    // MARK: Caption tier (footnotes, secondary descriptions)

    static let caption         = sans(size: 11, weight: .regular)
    static let captionEmphasis = sans(size: 11, weight: .medium)
    static let captionBold     = sans(size: 11, weight: .semibold)
    static let captionItalic   = sans(size: 11, weight: .regular, italic: true)
    static let captionSm       = sans(size: 10, weight: .regular)

    // MARK: Micro tier (dense metadata, kbd hints)

    static let micro           = sans(size: 10, weight: .regular)
    static let microEmphasis   = sans(size: 10, weight: .medium)
    /// 10pt Bold — attention metadata / badge fill.
    static let microBold       = sans(size: 10, weight: .bold)
    static let microItalic     = sans(size: 10, weight: .regular, italic: true)

    // MARK: Overline tier
    // Uppercase category labels ("PROJECTS", "TEAMS"). Callers add
    // `.tracking(0.6)` on the `Text` view; SwiftUI `Font` has no
    // intrinsic tracking so the View modifier is the right layer.

    static let overlineLg      = sans(size: 11, weight: .bold)
    static let overline        = sans(size: 10, weight: .semibold)

    // MARK: Mono scale (SF Mono, always monospaced design)

    /// Monospace variants — see header doc. Kept on SF Mono (system
    /// `.monospaced` design) so columns line up; Jakarta Sans is a
    /// proportional family and would break the "this is data / code"
    /// reading. Ordered largest → smallest.
    static let monoHeading      = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let monoBody         = Font.system(size: 13, weight: .regular,  design: .monospaced)
    static let monoBodyEmphasis = Font.system(size: 13, weight: .medium,   design: .monospaced)
    static let monoDefault      = Font.system(size: 14, weight: .regular,  design: .monospaced)
    static let monoDefaultEmph  = Font.system(size: 14, weight: .medium,   design: .monospaced)
    static let monoLabel        = Font.system(size: 12, weight: .medium,   design: .monospaced)
    static let monoRow          = Font.system(size: 12, weight: .regular,  design: .monospaced)
    static let monoCallout      = Font.system(size: 11, weight: .medium,   design: .monospaced)
    static let monoCaption      = Font.system(size: 11, weight: .regular,  design: .monospaced)
    static let monoMicro        = Font.system(size: 10, weight: .regular,  design: .monospaced)
    static let monoMicroEmph    = Font.system(size: 10, weight: .medium,   design: .monospaced)
    static let monoBadge        = Font.system(size: 10, weight: .bold,     design: .monospaced)
    static let monoBadgeSmall   = Font.system(size: 9,  weight: .bold,     design: .monospaced)

    // MARK: Arbitrary sizes / escape hatches

    /// Escape hatch for one-offs. Prefer a named scale entry; this
    /// exists so callers don't have to drop back to `.system(...)`.
    /// When `italic: true`, the matching italic face of the family is
    /// resolved (falls back to Regular Italic for the plain "Italic"
    /// TTF name used by Jakarta Sans for its regular italic).
    static func sans(
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        // Look up the matching Jakarta Sans PostScript name. If the font
        // registered successfully at launch, this returns a real Jakarta
        // font; otherwise SwiftUI gracefully falls back to the system
        // font at the same size/weight, so the UI never degrades to
        // unreadable Times New Roman.
        if let name = postscriptName(for: weight, italic: italic),
           NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
                .weight(weight)
        }
        if italic {
            return .system(size: size, weight: weight).italic()
        }
        return .system(size: size, weight: weight)
    }

    /// AppKit bridge: NSFont equivalent of `sans(size:weight:italic:)`,
    /// used when an AppKit view / NSTextField needs a concrete font
    /// object instead of a SwiftUI `Font`.
    static func nsFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false
    ) -> NSFont {
        if let name = postscriptName(for: swiftUIWeight(from: weight), italic: italic),
           let f = NSFont(name: name, size: size) {
            return f
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let italicDescriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: italicDescriptor, size: size) ?? base
        }
        return base
    }

    // MARK: Font registration

    /// Register all Jakarta Sans TTFs shipped in `Resources/Fonts` with
    /// Core Text so `NSFont(name:)` can find them. Idempotent — Core
    /// Text tolerates double-registration with a logged warning, but
    /// we guard with `registered` anyway to keep logs clean.
    ///
    /// Call this once, as early as possible (`TadoApp.init`). All UI
    /// rendering after the call will resolve Jakarta Sans; anything
    /// rendered before falls back to the system font.
    static func registerFonts() {
        guard !registered else { return }
        registered = true

        let urls = Bundle.module.urls(
            forResourcesWithExtension: "ttf",
            subdirectory: "Fonts"
        ) ?? []

        guard !urls.isEmpty else {
            NSLog("tado: Typography.registerFonts found no TTFs in Resources/Fonts")
            return
        }

        // Register one URL at a time via the sync per-URL API. The
        // batch `CTFontManagerRegisterFontURLs` uses a completion
        // handler (async) — for app-launch registration we want the
        // fonts available before the first view renders, which means
        // the synchronous variant.
        for url in urls {
            var errorRef: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &errorRef
            )
            if !ok {
                let msg = errorRef.map { String(describing: $0.takeRetainedValue()) } ?? "nil"
                NSLog("tado: Typography.registerFonts failed for \(url.lastPathComponent): \(msg)")
            }
        }
    }

    private static var registered = false

    // MARK: - Internal helpers

    /// Map a SwiftUI weight to the PostScript name of the matching
    /// Jakarta Sans face. The family ships eight weights × two styles;
    /// upright + italic are both resolved here.
    ///
    /// Regular Italic is a naming special case: Jakarta Sans ships it
    /// as `PlusJakartaSans-Italic` (not `-RegularItalic`), so the
    /// `.regular` + `italic: true` branch hits that file explicitly.
    private static func postscriptName(
        for weight: Font.Weight,
        italic: Bool = false
    ) -> String? {
        let base: String
        switch weight {
        case .ultraLight, .thin:
            base = "ExtraLight"
        case .light:
            base = "Light"
        case .regular:
            base = "Regular"
        case .medium:
            base = "Medium"
        case .semibold:
            base = "SemiBold"
        case .bold:
            base = "Bold"
        case .heavy, .black:
            base = "ExtraBold"
        default:
            base = "Regular"
        }
        if italic {
            // Jakarta Sans uses "Italic" (not "RegularItalic") for its
            // regular italic face.
            let suffix = (base == "Regular") ? "Italic" : "\(base)Italic"
            return "PlusJakartaSans-\(suffix)"
        }
        return "PlusJakartaSans-\(base)"
    }

    /// NSFont.Weight → Font.Weight (SwiftUI's values are opaque
    /// Double-backed, so we translate through the closest canonical
    /// macOS weight).
    private static func swiftUIWeight(from ns: NSFont.Weight) -> Font.Weight {
        switch ns {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}
