import SwiftUI

/// The top-level Dome surfaces the extension window shows. `.search`
/// is FIRST in `allCases` and is the default-active surface — Dome's
/// front door is "find first, then drill in".
///
/// - **Search** — global query → ranked notes/topics across the active scope.
/// - **User Notes** — primary write surface for humans.
/// - **Agent Notes** — read surface; agents write via the MCP server.
/// - **Calendar** — timeline of events + automations.
/// - **Knowledge** — tag/topic tree over all notes.
/// - **Recipes** — v0.11 — browse + run governed-answer templates.
/// - **Automation** — v0.11 — schedule + manage recurring agent runs.
enum DomeSurfaceTab: String, CaseIterable, Identifiable {
    case search
    case userNotes
    case agentNotes
    case calendar
    case knowledge
    case recipes
    case automation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .userNotes: return "User Notes"
        case .agentNotes: return "Agent Notes"
        case .calendar: return "Calendar"
        case .knowledge: return "Knowledge"
        case .recipes: return "Recipes"
        case .automation: return "Automation"
        }
    }

    /// SF Symbol for the sidebar icon. Chosen to read correctly at
    /// 13pt without regular-weight bleed.
    var iconSystemName: String {
        switch self {
        case .search: return "magnifyingglass"
        case .userNotes: return "person.text.rectangle"
        case .agentNotes: return "sparkles.rectangle.stack"
        case .calendar: return "calendar"
        case .knowledge: return "square.grid.3x2"
        case .recipes: return "text.book.closed"
        case .automation: return "clock.arrow.circlepath"
        }
    }
}

enum DomeKnowledgePage: String, CaseIterable, Identifiable {
    case list
    case graph
    case system
    case topics
    case packs
    case suggestions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .graph: return "Graph"
        case .system: return "System"
        case .topics: return "Topics"
        case .packs: return "Packs"
        case .suggestions: return "Suggestions"
        }
    }

    var iconSystemName: String {
        switch self {
        case .list: return "list.bullet.rectangle"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .system: return "waveform.path.ecg.rectangle"
        case .topics: return "tag"
        case .packs: return "shippingbox"
        case .suggestions: return "pencil.and.list.clipboard"
        }
    }
}
