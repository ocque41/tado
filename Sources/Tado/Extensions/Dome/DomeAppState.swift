import Foundation
import Observation

/// Cross-surface state for the Dome extension window.
///
/// Holds **only** state that is shared across more than one surface: which
/// surface is active, the active scope, whether to merge global data into
/// project views, and the in-flight free-text query/filters that the
/// upcoming Search front door will need to surface from any tab.
///
/// Per-surface state (e.g. the `KnowledgeSurface` page picker, the
/// `UserNotesSurface` editor buffer, the `CalendarSurface` month cursor)
/// stays local to each surface — see the P0 contract in the Eternal brief.
@Observable
final class DomeAppState {
    var activeSurface: DomeSurfaceTab
    var activeScopeID: String
    var includeGlobalData: Bool
    var searchQuery: String
    var globalFilters: DomeGlobalFilters
    /// Monotonic counter the hotkey registrar bumps when `Cmd+F`
    /// fires. The search field watches this with `onChange` and pulls
    /// focus to itself — using a counter (not a Bool) sidesteps the
    /// "can't toggle false from inside a focus handler without
    /// fighting the FocusState" trap. Cross-surface because the
    /// registrar lives in `DomeRootView` and the consumer is
    /// `SearchSurface`.
    var searchFocusRequest: Int

    init(
        activeSurface: DomeSurfaceTab = DomeSurfaceTab.allCases.first ?? .userNotes,
        activeScopeID: String = "global",
        includeGlobalData: Bool = true,
        searchQuery: String = "",
        globalFilters: DomeGlobalFilters = DomeGlobalFilters(),
        searchFocusRequest: Int = 0
    ) {
        self.activeSurface = activeSurface
        self.activeScopeID = activeScopeID
        self.includeGlobalData = includeGlobalData
        self.searchQuery = searchQuery
        self.globalFilters = globalFilters
        self.searchFocusRequest = searchFocusRequest
    }
}

/// Cross-surface filter set. Lives on `DomeAppState` so the search bar
/// and the activity ledger can share a single chip row in P2+.
struct DomeGlobalFilters: Equatable {
    var kinds: Set<String>
    var since: Date?

    init(kinds: Set<String> = [], since: Date? = nil) {
        self.kinds = kinds
        self.since = since
    }
}
