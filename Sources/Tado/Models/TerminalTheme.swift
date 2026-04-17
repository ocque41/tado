import AppKit

/// Curated terminal color palette — blends Claude brand colors and macOS Terminal.app
/// classics. Used to randomize the background/foreground of each new terminal tile
/// when AppSettings.randomTileColor is true.
struct TerminalTheme: Hashable, Identifiable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    /// Optional 16-slot ANSI palette (`0xRRGGBBAA`). Indices 0..<8 are
    /// normal colors (matches SGR 30..=37/40..=47), 8..<16 are bright.
    /// Nil falls back to the gruvbox-flavored default baked into
    /// `tado-core` so themes don't have to specify a palette to exist.
    let ansiPalette: [UInt32]?

    init(
        id: String,
        name: String,
        background: NSColor,
        foreground: NSColor,
        ansiPalette: [UInt32]? = nil
    ) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        if let p = ansiPalette {
            precondition(p.count == 16, "ANSI palette must be exactly 16 colors")
        }
        self.ansiPalette = ansiPalette
    }

    // MARK: - Tado / Claude

    /// Original Tado tile color — kept as the deterministic fallback so existing
    /// sessions look the same when randomization is disabled.
    static let tadoDark = TerminalTheme(
        id: "tado-dark",
        name: "Tado Dark",
        background: NSColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 1.0),
        foreground: NSColor(red: 0.804, green: 0.839, blue: 0.957, alpha: 1.0)
    )

    static let claudeCopper = TerminalTheme(
        id: "claude-copper",
        name: "Claude Copper",
        background: NSColor(red: 0.110, green: 0.090, blue: 0.075, alpha: 1.0),
        foreground: NSColor(red: 0.965, green: 0.760, blue: 0.520, alpha: 1.0)
    )

    static let claudeInk = TerminalTheme(
        id: "claude-ink",
        name: "Claude Ink",
        background: NSColor(red: 0.078, green: 0.078, blue: 0.078, alpha: 1.0),
        foreground: NSColor(red: 0.945, green: 0.886, blue: 0.733, alpha: 1.0)
    )

    // MARK: - macOS Terminal.app classics

    static let macPro = TerminalTheme(
        id: "mac-pro",
        name: "Pro",
        background: NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
        foreground: NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
    )

    static let macHomebrew = TerminalTheme(
        id: "mac-homebrew",
        name: "Homebrew",
        background: NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
        foreground: NSColor(red: 0.169, green: 0.808, blue: 0.169, alpha: 1.0)
    )

    static let macOcean = TerminalTheme(
        id: "mac-ocean",
        name: "Ocean",
        background: NSColor(red: 0.137, green: 0.247, blue: 0.561, alpha: 1.0),
        foreground: NSColor(red: 0.965, green: 0.965, blue: 0.965, alpha: 1.0)
    )

    static let macGrass = TerminalTheme(
        id: "mac-grass",
        name: "Grass",
        background: NSColor(red: 0.082, green: 0.353, blue: 0.078, alpha: 1.0),
        foreground: NSColor(red: 0.965, green: 0.882, blue: 0.737, alpha: 1.0)
    )

    static let macRedSands = TerminalTheme(
        id: "mac-red-sands",
        name: "Red Sands",
        background: NSColor(red: 0.439, green: 0.082, blue: 0.020, alpha: 1.0),
        foreground: NSColor(red: 1.0, green: 0.965, blue: 0.918, alpha: 1.0)
    )

    static let macSilverAerogel = TerminalTheme(
        id: "mac-silver-aerogel",
        name: "Silver Aerogel",
        background: NSColor(red: 0.918, green: 0.918, blue: 0.918, alpha: 1.0),
        foreground: NSColor(red: 0.220, green: 0.220, blue: 0.220, alpha: 1.0)
    )

    // MARK: - Popular community palettes

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: NSColor(red: 0.0, green: 0.169, blue: 0.212, alpha: 1.0),
        foreground: NSColor(red: 0.514, green: 0.580, blue: 0.588, alpha: 1.0),
        // Official Solarized palette — https://ethanschoonover.com/solarized/
        ansiPalette: [
            0x073642FF, // 0  base02 (black)
            0xDC322FFF, // 1  red
            0x859900FF, // 2  green
            0xB58900FF, // 3  yellow
            0x268BD2FF, // 4  blue
            0xD33682FF, // 5  magenta
            0x2AA198FF, // 6  cyan
            0xEEE8D5FF, // 7  base2 (white)
            0x002B36FF, // 8  base03 (bright black)
            0xCB4B16FF, // 9  orange (bright red)
            0x586E75FF, // 10 base01 (bright green)
            0x657B83FF, // 11 base00 (bright yellow)
            0x839496FF, // 12 base0 (bright blue)
            0x6C71C4FF, // 13 violet (bright magenta)
            0x93A1A1FF, // 14 base1 (bright cyan)
            0xFDF6E3FF  // 15 base3 (bright white)
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        background: NSColor(red: 0.157, green: 0.165, blue: 0.212, alpha: 1.0),
        foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1.0),
        // Dracula theme spec — https://spec.draculatheme.com/
        ansiPalette: [
            0x21222CFF, // 0  black
            0xFF5555FF, // 1  red
            0x50FA7BFF, // 2  green
            0xF1FA8CFF, // 3  yellow
            0xBD93F9FF, // 4  blue (purple)
            0xFF79C6FF, // 5  magenta (pink)
            0x8BE9FDFF, // 6  cyan
            0xF8F8F2FF, // 7  white
            0x6272A4FF, // 8  bright black (comment)
            0xFF6E6EFF, // 9  bright red
            0x69FF94FF, // 10 bright green
            0xFFFFA5FF, // 11 bright yellow
            0xD6ACFFFF, // 12 bright blue
            0xFF92DFFF, // 13 bright magenta
            0xA4FFFFFF, // 14 bright cyan
            0xFFFFFFFF  // 15 bright white
        ]
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        background: NSColor(red: 0.180, green: 0.204, blue: 0.251, alpha: 1.0),
        foreground: NSColor(red: 0.847, green: 0.871, blue: 0.914, alpha: 1.0),
        // Nord — https://www.nordtheme.com/docs/colors-and-palettes
        ansiPalette: [
            0x3B4252FF, 0xBF616AFF, 0xA3BE8CFF, 0xEBCB8BFF,
            0x81A1C1FF, 0xB48EADFF, 0x88C0D0FF, 0xE5E9F0FF,
            0x4C566AFF, 0xBF616AFF, 0xA3BE8CFF, 0xEBCB8BFF,
            0x81A1C1FF, 0xB48EADFF, 0x8FBCBBFF, 0xECEFF4FF
        ]
    )

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        background: NSColor(red: 0.157, green: 0.157, blue: 0.133, alpha: 1.0),
        foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1.0),
        ansiPalette: [
            0x272822FF, 0xF92672FF, 0xA6E22EFF, 0xF4BF75FF,
            0x66D9EFFF, 0xAE81FFFF, 0xA1EFE4FF, 0xF8F8F2FF,
            0x75715EFF, 0xF92672FF, 0xA6E22EFF, 0xF4BF75FF,
            0x66D9EFFF, 0xAE81FFFF, 0xA1EFE4FF, 0xF9F8F5FF
        ]
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        background: NSColor(red: 0.102, green: 0.114, blue: 0.176, alpha: 1.0),
        foreground: NSColor(red: 0.659, green: 0.706, blue: 0.871, alpha: 1.0),
        // Tokyo Night — https://github.com/enkia/tokyo-night-vscode-theme
        ansiPalette: [
            0x15161EFF, 0xF7768EFF, 0x9ECE6AFF, 0xE0AF68FF,
            0x7AA2F7FF, 0xBB9AF7FF, 0x7DCFFFFF, 0xA9B1D6FF,
            0x414868FF, 0xF7768EFF, 0x9ECE6AFF, 0xE0AF68FF,
            0x7AA2F7FF, 0xBB9AF7FF, 0x7DCFFFFF, 0xC0CAF5FF
        ]
    )

    static let gruvbox = TerminalTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        background: NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 1.0),
        foreground: NSColor(red: 0.922, green: 0.859, blue: 0.698, alpha: 1.0)
    )

    /// Tado's house theme. Deep neutral black (`#0A0A0A`) + near-white +
    /// burnt-sienna accent. The terminal content is intentionally DARKER
    /// than the app chrome — surface hierarchy reads deepest → shallowest:
    /// terminal body (`#0A0A0A`) → page body / canvas (`#1A1A1A`) →
    /// page headers + tile titlebars (`#2A2A2A`). No chromatic bleed:
    /// the bg is pure neutral so it sits naturally under `Palette.canvas`
    /// at the tile edge.
    ///
    /// ANSI palette keeps the burnt-sienna accent family for the warm
    /// hues (red/yellow/magenta) and muted sage/teal for green/cyan so
    /// `ls --color` output stays earthy rather than popping at you.
    /// Slot 0 (SGR 40) is locked to `#0A0A0A` so a black background
    /// escape doesn't flash a different color mid-stream.
    static let ember = TerminalTheme(
        id: "ember",
        name: "Ember",
        background: NSColor(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0, alpha: 1.0),
        foreground: NSColor(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0, alpha: 1.0),
        ansiPalette: [
            0x0A0A0AFF, // 0  black      — matches bg so SGR 40 doesn't flash
            0xA44718FF, // 1  red        — primary accent (burnt sienna)
            0x7A8F5AFF, // 2  green      — muted sage, reads earthy
            0xD4A043FF, // 3  yellow     — warm gold (leans orange, not lemon)
            0x6A6A95FF, // 4  blue       — desaturated neutral blue
            0xA8518BFF, // 5  magenta    — dusty rose
            0x5A8D95FF, // 6  cyan       — muted teal, sits cooler than accent
            0xD8D8D8FF, // 7  white      — off-white for normal text
            0x3A3A3AFF, // 8  bright black — neutral gray, visible on #0A0A0A
            0xC5613AFF, // 9  bright red — brighter burnt orange
            0x98AC7BFF, // 10 bright green — brighter sage
            0xE6BE5EFF, // 11 bright yellow
            0x8878B5FF, // 12 bright blue
            0xC37BA6FF, // 13 bright magenta
            0x7BABB3FF, // 14 bright cyan
            0xF5F5F5FF  // 15 bright white — matches fg
        ]
    )

    /// All themes in display order. Ember first — it's the brand default.
    static let all: [TerminalTheme] = [
        .ember,
        .tadoDark, .claudeCopper, .claudeInk,
        .macPro, .macHomebrew, .macOcean, .macGrass, .macRedSands, .macSilverAerogel,
        .solarizedDark, .dracula, .nord, .monokai, .tokyoNight, .gruvbox
    ]

    /// Pick a random theme. Never returns the previous theme on consecutive calls
    /// so back-to-back tile spawns visually differ.
    static func random(excluding previous: TerminalTheme? = nil) -> TerminalTheme {
        let pool = previous.map { prev in all.filter { $0 != prev } } ?? all
        return pool.randomElement() ?? .tadoDark
    }

    static func theme(id: String) -> TerminalTheme {
        all.first(where: { $0.id == id }) ?? .tadoDark
    }

    // MARK: - Packed RGBA for the Metal path

    /// Pack `background` / `foreground` into the `0xRRGGBBAA` encoding
    /// `TadoCore.Session.setDefaultColors(fg:bg:)` + the Metal shader use.
    /// NSColor components are converted into the sRGB space so theme colors
    /// look identical to the Cocoa-rendered SwiftTerm variants.
    var backgroundRGBA: UInt32 { Self.rgba(from: background) }
    var foregroundRGBA: UInt32 { Self.rgba(from: foreground) }

    private static func rgba(from color: NSColor) -> UInt32 {
        // Convert through sRGB so theme colors render the same in Metal
        // and Cocoa. Fall back to display P3 components if conversion
        // fails — extremely unlikely on macOS 14+.
        let converted = color.usingColorSpace(.sRGB) ?? color
        let r = UInt32(clamping: Int((converted.redComponent * 255).rounded()))
        let g = UInt32(clamping: Int((converted.greenComponent * 255).rounded()))
        let b = UInt32(clamping: Int((converted.blueComponent * 255).rounded()))
        let a = UInt32(clamping: Int((converted.alphaComponent * 255).rounded()))
        return (r << 24) | (g << 16) | (b << 8) | a
    }
}
