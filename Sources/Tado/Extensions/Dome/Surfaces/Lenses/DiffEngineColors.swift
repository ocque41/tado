import SwiftUI

extension DiffEngine.Origin {
    /// Marker glyph foreground colour the User-Notes and Agent-Notes
    /// diff lenses use. Lifted out of both surfaces so a future
    /// theme tweak (e.g. accessibility-friendly palette) lands once.
    var markerColor: Color {
        switch self {
        case .common: return Palette.textTertiary
        case .removedFromLeft: return Palette.danger
        case .addedOnRight: return Palette.success
        }
    }

    /// Row background tint for the diff lens. Same rationale as
    /// `markerColor` — keep both surfaces from drifting.
    var rowBackground: Color {
        switch self {
        case .common: return .clear
        case .removedFromLeft: return Palette.danger.opacity(0.12)
        case .addedOnRight: return Palette.success.opacity(0.12)
        }
    }
}
