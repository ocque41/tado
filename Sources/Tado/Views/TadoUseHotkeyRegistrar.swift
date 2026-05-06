import SwiftUI

/// Hidden, zero-sized button carrying the `Cmd+Shift+U` keyboard
/// shortcut. Lives inside `ContentView`'s root VStack so the
/// binding only fires when the main window is key. Same trick
/// `DomeHotkeyRegistrar` uses — SwiftUI resolves keyboard
/// shortcuts attached to focusable controls inside the active
/// window's view tree, so a zero-sized invisible button does the
/// job without showing chrome.
///
/// App-local only. There is no system-wide global hotkey
/// machinery in this codebase (verified: no Carbon /
/// `KeyboardShortcuts` / `MASShortcut` imports), and the user did
/// not ask for one. Cmd+Shift+U toggles the drawer iff Tado is
/// frontmost.
struct TadoUseHotkeyRegistrar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(action: { appState.showTadoUse.toggle() }) {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .accessibilityHidden(true)
    }
}
