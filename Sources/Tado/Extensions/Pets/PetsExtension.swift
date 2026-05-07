import SwiftUI

/// Tado Pets — animated floating pixel-art companion that
/// mirrors the live state of every active Tado surface
/// (terminal sessions, Eternal runs, Dispatch runs, perf gate)
/// across all macOS Spaces.
///
/// Inspired by OpenAI's Codex Pets (May 2026). What's different
/// here: Tado aggregates state across many concurrent agents,
/// so the pet uses busiest-state-wins resolution and the
/// click-to-expand popover gives a per-project, per-feature
/// breakdown.
///
/// Surfaces it owns
/// - The floating `NSPanel` (built on first show by
///   `PetsCoordinator`). Always-on-top, all-Spaces, borderless.
/// - The settings window (`PetsWindowRoot`) — what `makeView()`
///   returns. Reachable from the Extensions page, the
///   `Pet settings` button in the popover, and the
///   `.openExtensionWindowRequest` notification.
/// - The hatch sheet (`PetsHatchSheet`) — modal sheet presented
///   from the settings window or via `/hatch`.
///
/// Slash-command surface
/// `TodoCommand.detect` recognises `/pet` (toggle visibility)
/// and `/hatch <prompt>` (open the sheet with the prompt
/// prefilled). Both branches route through
/// `PetsCoordinator.shared`.
///
/// Lifecycle
/// `onAppLaunch()` bootstraps the coordinator (event-bus
/// subscription, settings observer, panel install if enabled).
/// The `MainWindowRoot` then calls
/// `PetsCoordinator.shared.bind(terminalManager:modelContainer:)`
/// when the manager is in scope so the coordinator can read
/// session + run state directly.
enum PetsExtension: AppExtension {
    static let manifest = ExtensionManifest(
        id: "pets",
        displayName: "Pets",
        shortDescription: "Floating animated companion that mirrors every active Tado agent across all macOS Spaces.",
        iconSystemName: "pawprint",
        version: "0.1.0",
        defaultWindowSize: ExtensionManifest.Size(width: 460, height: 640),
        windowResizable: true
    )

    @MainActor @ViewBuilder
    static func makeView() -> AnyView {
        AnyView(PetsWindowRoot())
    }

    static func onAppLaunch() async {
        await MainActor.run {
            PetsCoordinator.shared.bootstrap()
        }
    }
}
