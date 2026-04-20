import Foundation
import SwiftData
import AppKit

/// Out-of-process safety net for running Eternal sessions.
///
/// The external-loop wrapper (`eternal-loop.sh`) is what makes a worker
/// genuinely infinite — each iteration spawns a fresh `claude -p "..."`
/// session, resetting Claude Code's in-session Stop-hook recursion
/// counter. But the wrapper itself is a bash process on the user's
/// machine; it can hang, get OOM-killed, or wedge if the network or
/// the Claude CLI misbehaves.
///
/// This watchdog is the belt-and-suspenders layer: it wakes every 15
/// minutes, compares `state.json.lastActivityAt` against wall-clock,
/// and takes action on stalls.
///
/// Three states, cheapest to most drastic:
///
///   - **Healthy** (lastActivityAt < 10 min old): log and move on.
///   - **Stale** (10 - 30 min old): log the staleness; no intervention.
///     Heavy sprints with long agent turns legitimately go quiet for
///     a while.
///   - **Wedged** (≥ 30 min old AND tile session still alive): kill
///     the tile and re-spawn the worker from crafted.md. The wrapper's
///     state-file updates pick up from where they left off — sprints
///     counter, iterations, progress.md all survive.
///
/// Zero LLM tokens at any layer. Pure Swift + state.json polling.
@MainActor
final class EternalWatchdog {
    static let shared = EternalWatchdog()

    /// How often we wake. 15 minutes is a reasonable compromise: slow
    /// enough not to burn battery on idle systems, fast enough that a
    /// wedged worker doesn't burn hours before we notice.
    static let tickInterval: TimeInterval = 15 * 60

    /// Staleness at which we log a warning but do nothing.
    static let staleThreshold: TimeInterval = 10 * 60

    /// Staleness at which we kill + respawn. The upper bound is generous
    /// because a single APPLY turn on a code-heavy sprint can legitimately
    /// take 15-20 minutes.
    static let wedgedThreshold: TimeInterval = 30 * 60

    private var timer: Timer?
    private weak var terminalManagerRef: TerminalManager?
    private var modelContextRef: ModelContext?
    private weak var appStateRef: AppState?

    private init() {}

    /// Start the 15-min tick. Called from ContentView's `.task` once per
    /// app launch. Idempotent — calling `start` a second time cancels and
    /// reschedules.
    func start(
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        self.modelContextRef = modelContext
        self.terminalManagerRef = terminalManager
        self.appStateRef = appState
        stop()
        let t = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                EternalWatchdog.shared.tick()
            }
        }
        // Keep ticking across UI interaction runloops (menus, modals).
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run an out-of-cycle tick immediately. Useful for tests or a user-
    /// triggered "check now" action if we ever wire a menu item.
    func tickNow() {
        tick()
    }

    private func tick() {
        guard let modelContext = modelContextRef,
              let terminalManager = terminalManagerRef,
              let appState = appStateRef else { return }

        let descriptor = FetchDescriptor<EternalRun>()
        guard let runs = try? modelContext.fetch(descriptor) else { return }

        let now = Date().timeIntervalSince1970
        var didMutate = false

        for run in runs where run.state == "running" {
            let projectName = run.project?.name ?? "?"
            let todoID = run.workerTodoID
            let session = todoID.flatMap { terminalManager.session(forTodoID: $0) }

            // Session is gone — the wrapper's tile was killed or never
            // reconnected. Normally this means "mark stopped". But if
            // state.json shows the hook is still writing fresh activity,
            // the wrapper's bash loop is alive — the in-memory session
            // mapping just drifted. Rebind if we can find a matching tile
            // and trust state.json; only mark stopped when the hook has
            // also gone quiet.
            if session == nil {
                if EternalService.isHookFresh(run) {
                    let rebound = EternalService.reattachIfAlive(
                        run: run,
                        terminalManager: terminalManager
                    )
                    NSLog(
                        "EternalWatchdog: \(projectName)/\(run.label) session gone but state.json fresh — trusting hook (rebind: \(rebound))"
                    )
                    if rebound { didMutate = true }
                    continue
                }
                NSLog("EternalWatchdog: session gone for \(projectName)/\(run.label) — marking stopped")
                try? FileManager.default.removeItem(at: EternalService.activeFlagURL(run))
                if let data = try? Data(contentsOf: EternalService.stateFileURL(run)),
                   var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    obj["phase"] = "stopped"
                    if let updated = try? JSONSerialization.data(
                        withJSONObject: obj,
                        options: [.prettyPrinted, .sortedKeys]
                    ) {
                        try? updated.write(to: EternalService.stateFileURL(run), options: .atomic)
                    }
                }
                run.state = "stopped"
                run.workerTodoID = nil
                didMutate = true
                continue
            }

            // Session alive — check staleness.
            guard let state = EternalService.readState(run) else {
                NSLog("EternalWatchdog: \(projectName)/\(run.label) state.json unreadable — skipping")
                continue
            }
            let staleness = now - state.lastActivityAt

            if staleness >= Self.wedgedThreshold, let session = session {
                NSLog("EternalWatchdog: \(projectName)/\(run.label) wedged \(Int(staleness))s — respawning worker")
                // Kill the existing wrapper tile.
                terminalManager.terminateSession(session.id)
                // Clear active so the new wrapper can start clean.
                try? FileManager.default.removeItem(at: EternalService.activeFlagURL(run))
                run.workerTodoID = nil
                didMutate = true
                // Re-spawn. crafted.md / progress.md / metrics.jsonl all
                // persist, so the new wrapper continues where the old left
                // off. spawnWorker will re-write initial state.json (resets
                // iteration counter) and re-touch active.
                EternalService.spawnWorker(
                    run: run,
                    modelContext: modelContext,
                    terminalManager: terminalManager,
                    appState: appState
                )
            } else if staleness >= Self.staleThreshold {
                NSLog("EternalWatchdog: \(projectName)/\(run.label) stale \(Int(staleness))s (no action yet)")
            }
        }

        if didMutate {
            try? modelContext.save()
        }
    }
}
