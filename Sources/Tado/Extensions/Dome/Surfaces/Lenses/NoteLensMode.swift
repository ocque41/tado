import Foundation

/// Lens mode for the User Notes (P4) and Agent Notes (P5) surfaces.
///
/// Per the P0 contract, this is per-surface state — surfaces hold a
/// `@State` of this enum locally instead of bolting it onto
/// `DomeAppState`.
enum NoteLensMode: String, CaseIterable, Identifiable {
    case edit
    case diff
    case together

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .diff: return "Diff"
        case .together: return "Together"
        }
    }

    var subtitle: String {
        switch self {
        case .edit: return "Live editor"
        case .diff: return "Snapshot at last load vs current draft"
        case .together: return "Read-only merge across the active scope"
        }
    }
}
