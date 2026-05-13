// Single source of truth for the ⌘K palette items + the macOS
// menu bar items. Both surfaces read from this registry so they
// can never drift — adding a new action here adds it to both.
//
// Items are grouped (`SURFACES` / `ACTIONS` per brief section 8)
// and carry an optional keyboard shortcut hint that's rendered as
// a kbd pill in the palette and as the `keyboardShortcut(...)`
// modifier in the menu.

import SwiftUI

/// Group classification for the palette.
enum RelayCommandGroup: String, CaseIterable {
    case surfaces = "SURFACES"
    case actions = "ACTIONS"
    case projects = "PROJECTS"
    case sessions = "SESSIONS"
}

/// One palette / menu item.
struct CommandItem: Identifiable {
    let id: String
    let label: String
    let group: RelayCommandGroup
    /// Optional metadata shown to the right (palette) or as a kbd
    /// hint (menu). Examples: "GO TO", "⌘N", "OPEN".
    let meta: String?
    /// Optional 2-char hint (palette numeral). For surfaces this
    /// is the numeral (01, 02…); for actions it's `›`.
    let hint: String?
    /// Action to invoke when selected.
    let perform: () -> Void
}

/// Registry — owns the static surface list + dynamically resolves
/// the projects / teams / sessions list. Built fresh per palette
/// open so it picks up the latest data.
@MainActor
struct CommandRegistry {
    let appState: AppState
    let openWindow: OpenWindowAction
    /// Optional palette toggler — actions like "Toggle theme" can
    /// just run; "Open palette" itself wouldn't make sense as a
    /// palette item, so the palette never registers itself.
    let openPalette: () -> Void
    /// Toggle paper/ink. Read-only — the palette doesn't own the
    /// theme store; it just toggles via this closure.
    let toggleTheme: () -> Void
    let openExplore: () -> Void

    func items() -> [CommandItem] {
        var out: [CommandItem] = []
        out.append(contentsOf: surfaceItems())
        out.append(contentsOf: actionItems())
        return out
    }

    private func surfaceItems() -> [CommandItem] {
        var items: [CommandItem] = []
        for (idx, mode) in RelayTopNavBar.navOrder.enumerated() {
            items.append(CommandItem(
                id: "surface.\(mode.rawValue)",
                label: mode.label,
                group: .surfaces,
                meta: "GO TO",
                hint: String(format: "%02d", idx + 1)
            ) {
                navigate(to: mode)
            })
        }
        return items
    }

    private func actionItems() -> [CommandItem] {
        [
            CommandItem(
                id: "action.openExplore",
                label: "Open Explore",
                group: .actions,
                meta: "⌘E",
                hint: "›",
                perform: openExplore
            ),
            CommandItem(
                id: "action.toggleTheme",
                label: "Toggle theme",
                group: .actions,
                meta: "⌘T",
                hint: "›",
                perform: toggleTheme
            ),
            CommandItem(
                id: "action.openSettings",
                label: "Open Settings",
                group: .actions,
                meta: "⌘M",
                hint: "›"
            ) {
                appState.showSettings = true
            },
            CommandItem(
                id: "action.openDoneList",
                label: "Open Done list",
                group: .actions,
                meta: "⌘D",
                hint: "›"
            ) {
                appState.showDoneList = true
            },
            CommandItem(
                id: "action.openTrash",
                label: "Open Trash",
                group: .actions,
                meta: "⌘T",
                hint: "›"
            ) {
                appState.showTrashList = true
            },
            CommandItem(
                id: "action.toggleSidebar",
                label: "Toggle sidebar",
                group: .actions,
                meta: "⌘B",
                hint: "›"
            ) {
                appState.showSidebar.toggle()
            },
            CommandItem(
                id: "action.toggleTadoUse",
                label: "Toggle Tado Use",
                group: .actions,
                meta: "⌘⇧U",
                hint: "›"
            ) {
                appState.showTadoUse.toggle()
            },
        ]
    }

    private func navigate(to mode: ViewMode) {
        switch mode {
        case .knowledge:
            openWindow(id: ExtensionWindowID.string(for: DomeExtension.manifest.id))
        case .settings:
            appState.showSettings = true
        default:
            appState.currentView = mode
        }
    }
}
