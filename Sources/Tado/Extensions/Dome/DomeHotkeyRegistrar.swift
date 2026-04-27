import SwiftUI

/// Hand-rolled hotkey registrar — no new Swift packages per the
/// Eternal P6 brief. Implemented as a hidden `Group` of zero-sized
/// `Button`s, each carrying a `.keyboardShortcut` modifier. SwiftUI
/// resolves keyboard shortcuts attached to focusable controls in the
/// active window, so as long as the registrar is somewhere in the
/// Dome view hierarchy the bindings fire whenever the Dome window
/// is key.
///
/// Bindings (per the brief):
///   - `Cmd+1`..`Cmd+5` → pick surface in `DomeSurfaceTab.allCases`
///     order (Search, User Notes, Agent Notes, Calendar, Knowledge).
///   - `Cmd+F`         → focuses Search and switches to that tab.
///
/// The view writes through `DomeAppState`, so the same shortcut fires
/// whether the user is on the picker or has focus elsewhere in the
/// window.
struct DomeHotkeyRegistrar: View {
    @Environment(DomeAppState.self) private var domeState

    var body: some View {
        Group {
            // Surface picker bindings. The order of `allCases` is the
            // contract — `Cmd+1` MUST always be the first surface.
            ForEach(Array(DomeSurfaceTab.allCases.prefix(9).enumerated()), id: \.offset) { index, tab in
                Button(action: { domeState.activeSurface = tab }) {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: .command
                )
                .accessibilityHidden(true)
            }

            // Cmd+F → focus Search. Switch to the tab AND bump the
            // monotonic `searchFocusRequest` so SearchSurface's
            // `@FocusState` pulls focus to the TextField via its
            // `onChange` watcher.
            Button(action: {
                domeState.activeSurface = .search
                domeState.searchFocusRequest &+= 1
            }) {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }
}
