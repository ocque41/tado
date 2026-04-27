import XCTest
@testable import Tado

/// P0 acceptance — `DomeAppState` MUST hold only cross-surface state.
/// Per-surface fields (e.g. `KnowledgeSurface`'s `activeKnowledgePage`,
/// `UserNotesSurface`'s editor buffer, `CalendarSurface`'s month cursor)
/// are forbidden here. We enforce the contract via Swift reflection over
/// the property names of a default-initialized `DomeAppState`.
final class DomeAppStateTests: XCTestCase {

    /// Allow-list of permitted property names. Keep this list narrow —
    /// growth implies a contract change and should be discussed in a
    /// retro before being added.
    private static let allowedFields: Set<String> = [
        "activeSurface",
        "activeScopeID",
        "includeGlobalData",
        "searchQuery",
        "globalFilters",
        // P6 hardening — monotonic counter the hotkey registrar
        // bumps to focus the Search TextField. Cross-surface
        // (registrar in DomeRootView, consumer in SearchSurface).
        "searchFocusRequest",
    ]

    /// Property names that, if they ever appear on `DomeAppState`, mean
    /// per-surface state has leaked up. Each maps back to the surface
    /// that legitimately owns the field.
    private static let forbiddenFields: Set<String> = [
        "activeKnowledgePage",   // KnowledgeSurface
        "knowledgeExpanded",     // DomeRootView sidebar (presentation)
        "userNotesBuffer",       // UserNotesSurface
        "agentNotesSelection",   // AgentNotesSurface
        "calendarMonthCursor",   // CalendarSurface
        "diffSelectionLeft",     // P4/P5 surfaces
        "diffSelectionRight",
        "togetherMergedBuffer",
    ]

    private func propertyNames(of state: DomeAppState) -> Set<String> {
        var names = Set<String>()
        for child in Mirror(reflecting: state).children {
            guard let label = child.label else { continue }
            // The Observation `@Observable` macro injects synthesized
            // members such as `$observationRegistrar` and access keypath
            // helpers; skip macro plumbing so the contract reflects the
            // user-declared API only.
            if label.hasPrefix("$") || label == "_$observationRegistrar" {
                continue
            }
            // Stored properties may carry a leading "_" wrapper; strip
            // it so the contract compares cleanly against the public
            // property name.
            let stripped = label.hasPrefix("_") ? String(label.dropFirst()) : label
            names.insert(stripped)
        }
        return names
    }

    func testOnlyAllowedCrossSurfaceFieldsExist() {
        let state = DomeAppState()
        let names = propertyNames(of: state)
        let unexpected = names.subtracting(Self.allowedFields)
        XCTAssertTrue(
            unexpected.isEmpty,
            "DomeAppState contains unexpected fields: \(unexpected.sorted()). "
            + "Per-surface state must stay local — see the Eternal P0 contract."
        )
    }

    func testNoForbiddenPerSurfaceFields() {
        let state = DomeAppState()
        let names = propertyNames(of: state)
        let leaked = names.intersection(Self.forbiddenFields)
        XCTAssertTrue(
            leaked.isEmpty,
            "Per-surface state has leaked onto DomeAppState: \(leaked.sorted())"
        )
    }

    func testDefaultActiveSurfaceIsFirstAllCases() {
        // P1 will set Search FIRST in `allCases` — until then this just
        // pins the contract that `DomeAppState` defers to the enum's
        // declared order rather than hard-coding a tab.
        let state = DomeAppState()
        XCTAssertEqual(state.activeSurface, DomeSurfaceTab.allCases.first ?? .userNotes)
    }

    func testCrossSurfaceFieldsAreReadWrite() {
        let state = DomeAppState()
        state.activeSurface = .knowledge
        state.activeScopeID = "global"
        state.includeGlobalData = false
        state.searchQuery = "alpha"
        state.globalFilters = DomeGlobalFilters(kinds: ["dome.note"], since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(state.activeSurface, .knowledge)
        XCTAssertEqual(state.activeScopeID, "global")
        XCTAssertEqual(state.includeGlobalData, false)
        XCTAssertEqual(state.searchQuery, "alpha")
        XCTAssertEqual(state.globalFilters.kinds, ["dome.note"])
    }
}
