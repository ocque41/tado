import SwiftUI
import AppKit
import CoreText

/// Tado's typography system. One place that names every font size/weight
/// the app uses — views call `Typography.title` instead of repeating
/// `.system(size: 16, weight: .semibold)` inline, so re-tuning the scale
/// is a single edit.
///
/// The primary family is **Plus Jakarta Sans** (bundled in
/// `Resources/Fonts`, registered at app start by
/// `Typography.registerFonts()`). Terminal cells keep SF Mono — a
/// proportional sans can't drive a fixed-cell grid, and the renderer
/// silently falls back when the picked family lacks the monospace trait.
///
/// The scale is compact and macOS-native: this is a utility app that
/// lives in a small window, not a marketing site. Sizes descend in
/// roughly 1.2× steps so a heading reads clearly bigger than body copy
/// without needing a full 2× jump.
///
/// Scale:
///  - `display`  22pt Bold      — rare hero text (e.g., onboarding)
///  - `title`    16pt Semibold  — window / sheet titles
///  - `heading`  13pt Semibold  — section headers inside forms
///  - `label`    12pt Medium    — form row labels, prominent UI strings
///  - `body`     12pt Regular   — paragraph text, help copy
///  - `callout`  11pt Medium    — status chips, metadata
///  - `caption`  11pt Regular   — footnote / secondary descriptions
///  - `micro`    10pt Regular   — dense metadata, keyboard shortcut hints
///
/// Mono scale (SF Mono) — reserved for things that are *data*: todo text,
/// paths, grid coords, keyboard hints, agent ids. UI chrome reads as
/// Jakarta Sans; only the data sitting inside the chrome reads as code.
///  - `monoHeading`       13pt Semibold mono — dispatch modal title
///  - `monoBody`          13pt Regular mono  — dispatch body, project input
///  - `monoBodyEmphasis`  13pt Medium mono   — emphasized body
///  - `monoDefault`       14pt Regular mono  — todo row display name
///  - `monoDefaultEmph`   14pt Medium mono   — project / team row name
///  - `monoLabel`         12pt Medium mono   — selected agent name
///  - `monoRow`           12pt Regular mono  — sidebar session row text
///  - `monoCallout`       11pt Medium mono   — emphasized caption
///  - `monoCaption`       11pt Regular mono  — paths, 11pt secondary
///  - `monoMicro`         10pt Regular mono  — grid labels, metadata
///  - `monoMicroEmph`     10pt Medium mono   — agent name in titlebar
///  - `monoBadge`         10pt Bold mono     — queue/count pills
///  - `monoBadgeSmall`     9pt Bold mono     — titlebar unread count
enum Typography {
    // MARK: Font family

    /// PostScript family name registered from the bundled TTFs.
    /// `NSFont(name:size:)` returns nil for any weight we haven't
    /// registered, so the helpers below fall back to the matching
    /// system weight — defense against a missing file in a dev build.
    static let family = "Plus Jakarta Sans"

    // MARK: Scale

    static let display  = sans(size: 22, weight: .bold)
    static let title    = sans(size: 16, weight: .semibold)
    static let heading  = sans(size: 13, weight: .semibold)
    static let label    = sans(size: 12, weight: .medium)
    static let body     = sans(size: 12, weight: .regular)
    static let callout  = sans(size: 11, weight: .medium)
    static let caption  = sans(size: 11, weight: .regular)
    static let micro    = sans(size: 10, weight: .regular)
    // MARK: Mono scale

    /// Monospace variants — see header doc. Kept on SF Mono (system
    /// `.monospaced` design) so columns line up; Jakarta Sans is a
    /// proportional family and would break the "this is data / code"
    /// reading. Ordered largest → smallest to match the sans scale.
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

    // MARK: Arbitrary sizes

    /// Escape hatch for one-offs. Prefer a named scale entry; this
    /// exists so callers don't have to drop back to `.system(...)`.
    static func sans(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        // Look up the matching Jakarta Sans PostScript name. If the font
        // registered successfully at launch, this returns a real Jakarta
        // font; otherwise SwiftUI gracefully falls back to the system
        // font at the same size/weight, so the UI never degrades to
        // unreadable Times New Roman.
        if let name = postscriptName(for: weight), NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
                .weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// AppKit bridge: NSFont equivalent of `sans(size:weight:)`, used
    /// when an AppKit view / NSTextField needs a concrete font object
    /// instead of a SwiftUI `Font`.
    static func nsFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        if let name = postscriptName(for: swiftUIWeight(from: weight)),
           let f = NSFont(name: name, size: size) {
            return f
        }
        return .systemFont(ofSize: size, weight: weight)
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
    /// we only use the upright faces here (italic is reserved for a
    /// future "italic" slot in the scale if the UI ever needs emphasis).
    private static func postscriptName(for weight: Font.Weight) -> String? {
        switch weight {
        case .ultraLight, .thin:
            return "PlusJakartaSans-ExtraLight"
        case .light:
            return "PlusJakartaSans-Light"
        case .regular:
            return "PlusJakartaSans-Regular"
        case .medium:
            return "PlusJakartaSans-Medium"
        case .semibold:
            return "PlusJakartaSans-SemiBold"
        case .bold:
            return "PlusJakartaSans-Bold"
        case .heavy, .black:
            return "PlusJakartaSans-ExtraBold"
        default:
            return "PlusJakartaSans-Regular"
        }
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
