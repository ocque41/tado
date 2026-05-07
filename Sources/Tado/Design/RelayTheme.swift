// Theme propagation through the SwiftUI environment.
//
// `RelayTheme` is stored in `@AppStorage("relay.theme")` (default
// `.ink`). The active theme is injected at every WindowGroup root
// via `.relayTheme(_:)` so any descendant view can read it as
// `@Environment(\.relayTheme)`. All Relay components resolve their
// colors through this env so the user can flip paper/ink without a
// relaunch — every theme-dependent token re-evaluates on the next
// render.
//
// `.preferredColorScheme(.dark)` is replaced by
// `.preferredColorScheme(theme.swiftUIColorScheme)` at every
// WindowGroup root so the host appearance (sidebar fill, sheet
// chrome, focus rings) follows the chosen mode.

import SwiftUI

// MARK: - EnvironmentKey

private struct RelayThemeKey: EnvironmentKey {
    static let defaultValue: RelayTheme = .ink
}

extension EnvironmentValues {
    /// Active Relay theme (paper / ink) for the current view tree.
    /// Set at the WindowGroup root via `.relayTheme(_:)`. Defaults
    /// to `.ink` if unset.
    var relayTheme: RelayTheme {
        get { self[RelayThemeKey.self] }
        set { self[RelayThemeKey.self] = newValue }
    }
}

extension View {
    /// Inject a `RelayTheme` into the environment + apply the
    /// matching `.preferredColorScheme`. Call this at every
    /// WindowGroup root.
    func relayTheme(_ theme: RelayTheme) -> some View {
        environment(\.relayTheme, theme)
            .preferredColorScheme(theme.swiftUIColorScheme)
    }
}

// MARK: - Storage

/// Persistent theme storage. Uses the same `@AppStorage` key
/// across the app. Default is `.ink` per brief section 2.1
/// ("Default theme: dark"). The tweaks panel + Settings surface
/// both read/write this binding.
///
/// Use:
///
/// ```swift
/// @State private var themeStore = RelayThemeStore()
///
/// var body: some Scene {
///     WindowGroup { ... }
///         .relayTheme(themeStore.theme)
/// }
/// ```
@MainActor
@Observable
final class RelayThemeStore {
    private static let storageKey = "relay.theme"

    var theme: RelayTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = RelayTheme(rawValue: raw) {
            self.theme = stored
        } else {
            self.theme = .ink
        }
    }

    /// Toggle between paper and ink. Used by the titlebar accessory
    /// button + the tweaks panel switch.
    func toggle() {
        theme = (theme == .ink) ? .paper : .ink
    }
}
