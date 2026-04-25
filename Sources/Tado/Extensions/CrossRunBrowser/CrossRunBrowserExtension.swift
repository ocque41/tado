import SwiftUI

/// C6 — Cross-Run Browser.
///
/// One pane that aggregates every Eternal + Dispatch run across every
/// project into a single reverse-chronological timeline. Exists because
/// the project-detail views only show the runs attached to one project
/// at a time, which makes it hard to answer "what am I running?" at a
/// glance, and makes it impossible to spot patterns across projects
/// (e.g. "I always start sprints at 2 PM"). The browser is read-only —
/// edits still flow through the project-detail surfaces so the browser
/// never fights the canonical create/stop buttons.
///
/// Data sources
/// ------------
/// - `EternalRun` + `DispatchRun` via SwiftData `@Query`. Covers every
///   run bound to a project (current or deleted-with-project).
/// - For live eternal runs, `EternalService.readState(run)` adds the
///   sprint counter + last metric so the row shows freshness without
///   the user having to open the project.
///
/// UI shape
/// --------
/// Sidebar picker at left (All / Eternal / Dispatch / Active only),
/// scrollable table at right. Each row has a "Reveal in Finder" action
/// that opens the on-disk run directory — the same link the individual
/// project pages expose, but unified here.
enum CrossRunBrowserExtension: AppExtension {
    static let manifest = ExtensionManifest(
        id: "cross-run-browser",
        displayName: "Cross-Run Browser",
        shortDescription: "One timeline of every Eternal + Dispatch run across every project.",
        iconSystemName: "clock.arrow.2.circlepath",
        version: "0.1.0",
        defaultWindowSize: ExtensionManifest.Size(width: 900, height: 700),
        windowResizable: true
    )

    @MainActor @ViewBuilder
    static func makeView() -> AnyView {
        AnyView(CrossRunBrowserView())
    }
}
