import Foundation
import SwiftData

/// Publishes Eternal + Dispatch run events by watching the underlying
/// state files on disk. Bash hooks mutate the files; this watcher
/// diffs old vs new and emits typed `TadoEvent`s.
///
/// Per Eternal run:
///   - Watches `<.tado>/eternal/runs/<id>/state.json`.
///   - On `sprints` counter increment → `eternal.phaseCompleted`.
///   - On `phase` transitioning to `"completed"` → `eternal.runCompleted`.
///   - On `phase` transitioning to `"stopped"` → `eternal.runStopped`.
///
/// Per Dispatch run:
///   - Watches `<.tado>/dispatch/runs/<id>/phases/` (directory watch).
///   - Each phase is one JSON file with a `status` field; when a
///     file's status flips to `"completed"` → `dispatch.phaseCompleted`.
///   - When all phase statuses are `"completed"` → `dispatch.runCompleted`.
///
/// The watcher keeps an in-memory snapshot of the last-observed state
/// for each file so bursts of write churn collapse to one emitted
/// event per meaningful transition.
@MainActor
final class RunEventWatcher {
    private let container: ModelContainer
    private let context: ModelContext
    private var saveObserver: NSObjectProtocol?

    // Per-run watcher handles + last-observed state, so we publish
    // exactly once per real transition.
    private var eternalWatchers: [UUID: (FileWatcher, EternalState)] = [:]
    private var dispatchWatchers: [UUID: (FileWatcher, [String: String])] = [:]
    /// One-shot watchers per run that fire when `crafted.md` lands —
    /// the architect's "I'm done" signal. The Eternal state.json watcher
    /// is no help here because state.json is written by the worker,
    /// which doesn't spawn until the user accepts the review. Keyed by
    /// (kind, runID) so we never miss a transition; entries are torn
    /// down after the first fire so we can't double-publish.
    private var craftedWatchers: [String: FileWatcher] = [:]
    private var announcedReviews: Set<String> = []

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    func start() {
        attachWatchersToAllRuns()

        // Attach watchers for new runs as they arrive in SwiftData.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.attachWatchersToAllRuns() }
        }
    }

    // MARK: - Attach

    private func attachWatchersToAllRuns() {
        attachEternal()
        attachDispatch()
        attachCraftedWatchers()
    }

    /// Attach per-run watchers that wait for `crafted.md` to land. Eternal
    /// runs in `planning` watch the run dir; Dispatch runs in `planning`
    /// watch the run dir. On first sight of `crafted.md` we publish a
    /// `<kind>.awaitingReview` event, then tear the watcher down — the
    /// modal's open/accept flow takes over from there.
    private func attachCraftedWatchers() {
        let eternalDescriptor = FetchDescriptor<EternalRun>()
        let eternalRuns = (try? context.fetch(eternalDescriptor)) ?? []
        for run in eternalRuns where run.state == "planning" || run.state == "awaitingReview" {
            let key = "eternal:\(run.id.uuidString)"
            if announcedReviews.contains(key) { continue }
            if EternalService.craftedExistsOnDisk(run) {
                publishAwaitingReview(kind: .eternal, run: run)
                announcedReviews.insert(key)
                continue
            }
            if craftedWatchers[key] != nil { continue }
            let dir = EternalService.eternalRoot(run)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let runID = run.id
            let watcher = FileWatcher(url: dir) { [weak self] in
                Task { @MainActor in self?.checkEternalCrafted(runID: runID) }
            }
            craftedWatchers[key] = watcher
        }

        let dispatchDescriptor = FetchDescriptor<DispatchRun>()
        let dispatchRuns = (try? context.fetch(dispatchDescriptor)) ?? []
        for run in dispatchRuns where run.state == "planning" || run.state == "awaitingReview" {
            let key = "dispatch:\(run.id.uuidString)"
            if announcedReviews.contains(key) { continue }
            if DispatchPlanService.craftedExistsOnDisk(run) {
                publishAwaitingReview(kind: .dispatch, run: run)
                // Kanban materialization on relaunch: if the architect
                // finished writing the plan while Tado was quit, replay
                // the column reconciliation here so the canvas has the
                // right lanes when the user opens it. No-op for grid mode.
                DispatchPlanService.materializeKanbanColumns(
                    run: run,
                    modelContext: context
                )
                announcedReviews.insert(key)
                continue
            }
            if craftedWatchers[key] != nil { continue }
            let dir = DispatchPlanService.dispatchRoot(run)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let runID = run.id
            let watcher = FileWatcher(url: dir) { [weak self] in
                Task { @MainActor in self?.checkDispatchCrafted(runID: runID) }
            }
            craftedWatchers[key] = watcher
        }
    }

    private func checkEternalCrafted(runID: UUID) {
        let descriptor = FetchDescriptor<EternalRun>()
        guard let runs = try? context.fetch(descriptor),
              let run = runs.first(where: { $0.id == runID }) else { return }
        guard EternalService.craftedExistsOnDisk(run) else { return }
        let key = "eternal:\(runID.uuidString)"
        guard !announcedReviews.contains(key) else { return }
        announcedReviews.insert(key)
        publishAwaitingReview(kind: .eternal, run: run)
        craftedWatchers[key]?.cancel()
        craftedWatchers.removeValue(forKey: key)
    }

    private func checkDispatchCrafted(runID: UUID) {
        let descriptor = FetchDescriptor<DispatchRun>()
        guard let runs = try? context.fetch(descriptor),
              let run = runs.first(where: { $0.id == runID }) else { return }
        guard DispatchPlanService.craftedExistsOnDisk(run) else { return }
        let key = "dispatch:\(runID.uuidString)"
        guard !announcedReviews.contains(key) else { return }
        announcedReviews.insert(key)
        publishAwaitingReview(kind: .dispatch, run: run)
        // Kanban mode — materialize one KanbanColumn per phase the
        // architect just wrote. Idempotent on the helper's side, so
        // re-plans (which fire this same callback after the modal's
        // re-plan path) reconcile cleanly. Grid-mode runs short-circuit
        // inside the helper; calling unconditionally avoids splitting
        // the watcher's logic.
        DispatchPlanService.materializeKanbanColumns(
            run: run,
            modelContext: context
        )
        craftedWatchers[key]?.cancel()
        craftedWatchers.removeValue(forKey: key)
    }

    private func publishAwaitingReview(kind: CraftedReviewKind, run: EternalRun) {
        let runLabel = shortID(run.id)
        EventBus.shared.publish(
            TadoEvent(
                type: "eternal.awaitingReview",
                severity: .warning,
                source: .init(
                    kind: "eternal",
                    projectID: run.project?.id,
                    projectName: run.project?.name,
                    runID: run.id
                ),
                title: "Eternal plan ready for review (\(runLabel))",
                body: "Architect finished crafting the brief. Open Tado to accept or re-plan."
            )
        )
    }

    private func publishAwaitingReview(kind: CraftedReviewKind, run: DispatchRun) {
        let runLabel = shortID(run.id)
        EventBus.shared.publish(
            TadoEvent(
                type: "dispatch.awaitingReview",
                severity: .warning,
                source: .init(
                    kind: "dispatch",
                    projectID: run.project?.id,
                    projectName: run.project?.name,
                    runID: run.id
                ),
                title: "Dispatch plan ready for review (\(runLabel))",
                body: "Architect finished planning the phases. Open Tado to accept or re-plan."
            )
        )
    }

    private func attachEternal() {
        let descriptor = FetchDescriptor<EternalRun>()
        let runs = (try? context.fetch(descriptor)) ?? []
        let liveIDs = Set(runs.map(\.id))

        for run in runs where !isTerminal(eternalState: run.state) {
            if eternalWatchers[run.id] != nil { continue }
            let url = EternalService.stateFileURL(run)
            let initial = EternalService.readState(run) ?? EternalState()
            let watcher = FileWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.handleEternalFire(runID: run.id) }
            }
            eternalWatchers[run.id] = (watcher, initial)
        }

        // Tear down watchers for runs that (a) reached a terminal
        // state, or (b) no longer exist in SwiftData (cascade-delete
        // from project removal, manual delete, etc.). Both cases
        // would otherwise leak a FileWatcher fd forever.
        for (id, _) in eternalWatchers {
            let still = runs.first(where: { $0.id == id })
            let shouldDetach = !liveIDs.contains(id)
                || (still.map { isTerminal(eternalState: $0.state) } ?? true)
            if shouldDetach {
                eternalWatchers[id]?.0.cancel()
                eternalWatchers.removeValue(forKey: id)
            }
        }
    }

    private func attachDispatch() {
        let descriptor = FetchDescriptor<DispatchRun>()
        let runs = (try? context.fetch(descriptor)) ?? []
        let liveIDs = Set(runs.map(\.id))

        for run in runs where !isTerminal(dispatchState: run.state) {
            if dispatchWatchers[run.id] != nil { continue }
            let dir = DispatchPlanService.phasesDirURL(run)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let initial = readPhaseStatuses(in: dir)
            let watcher = FileWatcher(url: dir) { [weak self] in
                Task { @MainActor in self?.handleDispatchFire(runID: run.id) }
            }
            dispatchWatchers[run.id] = (watcher, initial)
        }

        for (id, _) in dispatchWatchers {
            let still = runs.first(where: { $0.id == id })
            let shouldDetach = !liveIDs.contains(id)
                || (still.map { isTerminal(dispatchState: $0.state) } ?? true)
            if shouldDetach {
                dispatchWatchers[id]?.0.cancel()
                dispatchWatchers.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Fires

    private func handleEternalFire(runID: UUID) {
        let descriptor = FetchDescriptor<EternalRun>()
        guard let runs = try? context.fetch(descriptor),
              let run = runs.first(where: { $0.id == runID }),
              let newState = EternalService.readState(run) else { return }

        let old = eternalWatchers[runID]?.1 ?? EternalState()
        eternalWatchers[runID]?.1 = newState

        let projectName = run.project?.name
        let runLabel = shortID(run.id)

        if newState.sprints > old.sprints {
            let metric = newState.lastMetric?.display ?? "—"
            EventBus.shared.publish(
                TadoEvent(
                    type: "eternal.phaseCompleted",
                    severity: .success,
                    source: .init(
                        kind: "eternal",
                        projectID: run.project?.id,
                        projectName: projectName,
                        runID: run.id
                    ),
                    title: "Sprint \(newState.sprints) complete (\(runLabel))",
                    body: "Metric: \(metric)"
                )
            )
            // C5: mirror the sprint retro into Dome so future
            // architects can dome_search it. v0.10 Phase 3 lands a
            // structured retro alongside the legacy line — the
            // deterministic extractor lifts each "## …" section into
            // its own typed graph_node + provenance edge, and the
            // deduper chains repeat retros via supersede.
            if let project = run.project {
                let retroLine = "Sprint \(newState.sprints) complete (run \(runLabel)). Metric: \(metric). Iterations so far: \(newState.iterations). Last progress: \(newState.lastProgressNote ?? "—")"
                DomeProjectMemory.appendOverview(for: project, line: retroLine)
                DomeProjectMemory.appendStructuredRetro(
                    for: project,
                    runID: run.id,
                    kind: "eternal-sprint",
                    outcome: "Sprint \(newState.sprints) complete (run \(runLabel)). Iterations so far: \(newState.iterations).",
                    decision: nil,
                    caveats: nil,
                    cites: ["metric: \(metric)"],
                    nextAgentNote: newState.lastProgressNote
                )
            }
        }

        // Performance step — fires whenever perfCycles ticks. Three
        // event flavors so the dashboard pill colour-shifts correctly;
        // a `kind: "eternal-perf"` Dome retro is always written so
        // future architects can dome_search it. The retro records the
        // composite delta + the offending sub-metric on regression so
        // the next architect's IMPROVE ladder can target the actual
        // hot path instead of guessing.
        if newState.perfCycles > old.perfCycles {
            let composite = newState.lastPerfScore ?? 0
            let isRegression = newState.perfRegressionDelta != nil
            let event: TadoEvent
            if let delta = newState.perfRegressionDelta {
                event = .eternalPerfRegressed(runID: run.id, projectName: projectName, composite: composite, delta: delta)
            } else if let prev = old.lastPerfScore, composite > prev + 0.005 {
                event = .eternalPerfImproved(runID: run.id, projectName: projectName, composite: composite, delta: composite - prev)
            } else {
                event = .eternalPerfHeld(runID: run.id, projectName: projectName, composite: composite)
            }
            EventBus.shared.publish(event)
            if let project = run.project {
                let outcome: String
                if isRegression, let delta = newState.perfRegressionDelta {
                    outcome = "Perf cycle \(newState.perfCycles): regressed by \(String(format: "%.3f", delta)) (composite=\(String(format: "%.3f", composite))). Run \(runLabel)."
                } else {
                    outcome = "Perf cycle \(newState.perfCycles): composite=\(String(format: "%.3f", composite)). Run \(runLabel)."
                }
                let cites: [String] = [
                    "composite: \(String(format: "%.3f", composite))",
                    "report: \(newState.lastPerfReportPath ?? "—")",
                ]
                let nextNote: String? = isRegression
                    ? "Perf regressed last cycle — IMPROVE ladder should focus on the largest-loss sub-metric in perf-report.json."
                    : newState.lastProgressNote
                DomeProjectMemory.appendStructuredRetro(
                    for: project,
                    runID: run.id,
                    kind: "eternal-perf",
                    outcome: outcome,
                    decision: nil,
                    caveats: isRegression ? "Baseline NOT updated this cycle." : nil,
                    cites: cites,
                    nextAgentNote: nextNote
                )
            }
        }

        if newState.phase != old.phase {
            switch newState.phase {
            case "completed":
                EventBus.shared.publish(
                    TadoEvent(
                        type: "eternal.runCompleted",
                        severity: .success,
                        source: .init(
                            kind: "eternal",
                            projectID: run.project?.id,
                            projectName: projectName,
                            runID: run.id
                        ),
                        title: "Eternal run completed (\(runLabel))",
                        body: "\(newState.sprints) sprints, \(newState.iterations) iterations."
                    )
                )
                // C5: write a structured completion retro to Dome.
                // Phase 3 ships a typed-section retro alongside the
                // legacy line so the extractor can lift Outcome /
                // Decision / Caveats into separate `graph_nodes`.
                if let project = run.project {
                    let retroLine = "Eternal run \(runLabel) COMPLETED. Mode: \(newState.mode). Final sprints: \(newState.sprints). Iterations: \(newState.iterations). Final metric: \(newState.lastMetric?.display ?? "—"). Last note: \(newState.lastProgressNote ?? "—")"
                    DomeProjectMemory.appendOverview(for: project, line: retroLine)
                    DomeProjectMemory.appendStructuredRetro(
                        for: project,
                        runID: run.id,
                        kind: "eternal-completion",
                        outcome: "Run \(runLabel) completed in mode \(newState.mode). Final: \(newState.sprints) sprints, \(newState.iterations) iterations.",
                        decision: nil,
                        caveats: nil,
                        cites: [
                            "metric: \(newState.lastMetric?.display ?? "—")"
                        ],
                        nextAgentNote: newState.lastProgressNote
                    )
                }
            case "stopped":
                EventBus.shared.publish(
                    TadoEvent(
                        type: "eternal.runStopped",
                        severity: .warning,
                        source: .init(
                            kind: "eternal",
                            projectID: run.project?.id,
                            projectName: projectName,
                            runID: run.id
                        ),
                        title: "Eternal run stopped (\(runLabel))",
                        body: "Phase: \(old.phase) → stopped."
                    )
                )
            default:
                break
            }
        }
    }

    private func handleDispatchFire(runID: UUID) {
        let descriptor = FetchDescriptor<DispatchRun>()
        guard let runs = try? context.fetch(descriptor),
              let run = runs.first(where: { $0.id == runID }) else { return }

        let dir = DispatchPlanService.phasesDirURL(run)
        let newStatuses = readPhaseStatuses(in: dir)
        let oldStatuses = dispatchWatchers[runID]?.1 ?? [:]
        dispatchWatchers[runID]?.1 = newStatuses

        let projectName = run.project?.name
        let runLabel = shortID(run.id)

        // Per-phase "completed" transitions.
        for (id, newStatus) in newStatuses {
            let oldStatus = oldStatuses[id]
            if oldStatus != "completed", newStatus == "completed" {
                EventBus.shared.publish(
                    TadoEvent(
                        type: "dispatch.phaseCompleted",
                        severity: .success,
                        source: .init(
                            kind: "dispatch",
                            projectID: run.project?.id,
                            projectName: projectName,
                            runID: run.id
                        ),
                        title: "Dispatch phase \(id) complete (\(runLabel))",
                        body: ""
                    )
                )
            }
        }

        // All phases completed → run completed (fire once per flip).
        let allCompleted = !newStatuses.isEmpty &&
            newStatuses.values.allSatisfy { $0 == "completed" }
        let wasAllCompleted = !oldStatuses.isEmpty &&
            oldStatuses.values.allSatisfy { $0 == "completed" }
        if allCompleted && !wasAllCompleted {
            EventBus.shared.publish(
                TadoEvent(
                    type: "dispatch.runCompleted",
                    severity: .success,
                    source: .init(
                        kind: "dispatch",
                        projectID: run.project?.id,
                        projectName: projectName,
                        runID: run.id
                    ),
                    title: "Dispatch run completed (\(runLabel))",
                    body: "\(newStatuses.count) phases complete."
                )
            )
            // Phase 3 — structured retro. The deterministic extractor
            // lifts each section into its own typed graph_node so a
            // future agent's `dome_search` can find "what dispatch
            // landed for project X" without scraping freeform prose.
            if let project = run.project {
                let phaseList = newStatuses.keys.sorted().joined(separator: ", ")
                DomeProjectMemory.appendStructuredRetro(
                    for: project,
                    runID: run.id,
                    kind: "dispatch-completion",
                    outcome: "Dispatch run \(runLabel) completed with \(newStatuses.count) phases.",
                    decision: nil,
                    caveats: nil,
                    cites: ["phases: \(phaseList)"],
                    nextAgentNote: nil
                )
            }
        }
    }

    // MARK: - Helpers

    private func readPhaseStatuses(in dir: URL) -> [String: String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var out: [String: String] = [:]
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let phase = try? decoder.decode(PhaseJSON.self, from: data) else { continue }
            out[phase.id] = phase.status
        }
        return out
    }

    private func isTerminal(eternalState: String) -> Bool {
        eternalState == "completed" || eternalState == "stopped"
    }

    private func isTerminal(dispatchState: String) -> Bool {
        dispatchState == "completed" || dispatchState == "stopped"
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
