import SwiftUI

/// The four top-level Dome surfaces the extension window shows.
/// Rendering order matches the sidebar top-to-bottom: most-used
/// first.
///
/// - **User Notes** — primary write surface for humans.
/// - **Agent Notes** — read surface; agents write via the MCP server.
/// - **Calendar** — timeline of events + automations.
/// - **Knowledge** — tag/topic tree over all notes.
enum DomeSurfaceTab: String, CaseIterable, Identifiable {
    case userNotes
    case agentNotes
    case calendar
    case knowledge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .userNotes: return "User Notes"
        case .agentNotes: return "Agent Notes"
        case .calendar: return "Calendar"
        case .knowledge: return "Knowledge"
        }
    }

    /// SF Symbol for the sidebar icon. Chosen to read correctly at
    /// 13pt without regular-weight bleed.
    var iconSystemName: String {
        switch self {
        case .userNotes: return "person.text.rectangle"
        case .agentNotes: return "sparkles.rectangle.stack"
        case .calendar: return "calendar"
        case .knowledge: return "square.grid.3x2"
        }
    }
}

enum DomeKnowledgePage: String, CaseIterable, Identifiable {
    case list
    case graph
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .graph: return "Graph"
        case .system: return "System"
        }
    }

    var iconSystemName: String {
        switch self {
        case .list: return "list.bullet.rectangle"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .system: return "waveform.path.ecg.rectangle"
        }
    }
}
