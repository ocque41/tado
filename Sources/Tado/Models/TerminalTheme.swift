import AppKit

/// Curated terminal color palette — blends Claude brand colors and macOS Terminal.app
/// classics. Used to randomize the background/foreground of each new SwiftTerm tile
/// when AppSettings.randomTileColor is true.
struct TerminalTheme: Hashable, Identifiable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor

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
        foreground: NSColor(red: 0.514, green: 0.580, blue: 0.588, alpha: 1.0)
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        background: NSColor(red: 0.157, green: 0.165, blue: 0.212, alpha: 1.0),
        foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1.0)
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        background: NSColor(red: 0.180, green: 0.204, blue: 0.251, alpha: 1.0),
        foreground: NSColor(red: 0.847, green: 0.871, blue: 0.914, alpha: 1.0)
    )

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        background: NSColor(red: 0.157, green: 0.157, blue: 0.133, alpha: 1.0),
        foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1.0)
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        background: NSColor(red: 0.102, green: 0.114, blue: 0.176, alpha: 1.0),
        foreground: NSColor(red: 0.659, green: 0.706, blue: 0.871, alpha: 1.0)
    )

    static let gruvbox = TerminalTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        background: NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 1.0),
        foreground: NSColor(red: 0.922, green: 0.859, blue: 0.698, alpha: 1.0)
    )

    /// All themes in display order.
    static let all: [TerminalTheme] = [
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
}
