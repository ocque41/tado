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
