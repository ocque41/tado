import Foundation
import SwiftData

/// Coordinator-driven extensions on `DispatchPlanService`. Mirrors
/// `EternalServiceCoordinator` — three new methods (propose,
/// acceptReviewWithGuard, rejectReview) so the Unix-socket router
/// can drive Dispatch end-to-end without the project UI.
extension DispatchPlanService {

    enum AcceptResult: Equatable {
        case accepted
        case stateMismatch(actual: String)
        case notFound
    }

    enum RejectResult: Equatable {
        case rejected
        case stateMismatch(actual: String)
        case notFound
    }

    static func reviewNoteFileURL(_ run: DispatchRun) -> URL {
        dispatchRoot(run).appendingPathComponent("review-note.md")
    }

    static func rejectedCraftedArchiveURL(_ run: DispatchRun, timestamp: Date = Date()) -> URL {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let stamp = fmt.string(from: timestamp)
            .replacingOccurrences(of: ":", with: "-")
        return dispatchRoot(run)
            .appendingPathComponent("rejected-crafted-\(stamp).md")
    }

    /// Create a new `DispatchRun` from the coordinator's brief and
    /// drive the architect. Idempotent on `coordinatorTodoID`.
    @MainActor
    @discardableResult
    static func proposeViaCoordinator(
        project: Project,
        label: String,
        brief: String,
        coordinatorTodoID: UUID,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> DispatchRun {
        let descriptor = FetchDescriptor<DispatchRun>()
        if let existing = (try? modelContext.fetch(descriptor))?.first(where: { run in
            run.spawnedByCoordinatorTodoID == coordinatorTodoID
                && (run.state == "drafted"
                    || run.state == "planning"
                    || run.state == "awaitingReview"
                    || run.state == "ready")
        }) {
            return existing
        }

        let resolvedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DispatchRun.defaultLabel()
            : label

        let run = DispatchRun(
            project: project,
            label: resolvedLabel,
            brief: brief
        )
        run.spawnedByCoordinatorTodoID = coordinatorTodoID
        modelContext.insert(run)
        try? modelContext.save()

        spawnArchitect(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        EventBus.shared.publish(TadoEvent.coordinatorProposed(
            todoID: coordinatorTodoID,
            runID: run.id,
            kind: "dispatch",
            projectName: project.name
        ))
        return run
    }

    /// Optimistic-concurrency wrapper around `acceptReview`.
    /// Returns `stateMismatch(actual)` when the run has moved off
    /// `awaitingReview`. Writes `reviewNote` even on mismatch.
    @MainActor
    @discardableResult
    static func acceptReviewWithGuard(
        run: DispatchRun,
        expectedState: String,
        reviewNote: String?,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> AcceptResult {
        if let note = reviewNote, !note.isEmpty {
            try? FileManager.default.createDirectory(
                at: dispatchRoot(run),
                withIntermediateDirectories: true
            )
            try? note.write(to: reviewNoteFileURL(run), atomically: true, encoding: .utf8)
        }

        if run.state != expectedState {
            return .stateMismatch(actual: run.state)
        }

        let started = acceptReview(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        if started, let coordinatorID = run.spawnedByCoordinatorTodoID {
            EventBus.shared.publish(TadoEvent.coordinatorAccepted(
                todoID: coordinatorID,
                runID: run.id,
                kind: "dispatch",
                projectName: run.project?.name
            ))
        }
        return started ? .accepted : .stateMismatch(actual: run.state)
    }

    /// Reject the architect's plan. Archives `crafted.md` (and any
    /// associated `plan.json`) to a timestamped sidecar, optionally
    /// overwrites the brief, transitions back to `planning`, and
    /// re-spawns the architect.
    @MainActor
    @discardableResult
    static func rejectReview(
        run: DispatchRun,
        reason: String,
        rebrief: String?,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> RejectResult {
        if run.state != "awaitingReview" && run.state != "ready" {
            return .stateMismatch(actual: run.state)
        }

        let fm = FileManager.default
        let crafted = craftedFileURL(run)
        if fm.fileExists(atPath: crafted.path) {
            let archive = rejectedCraftedArchiveURL(run)
            let header = "<!-- rejected: \(reason) -->\n\n".data(using: .utf8) ?? Data()
            if let body = try? Data(contentsOf: crafted) {
                try? (header + body).write(to: archive)
            } else {
                try? header.write(to: archive)
            }
        }

        if let rebrief, !rebrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            run.brief = rebrief
        }

        spawnArchitect(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        if let coordinatorID = run.spawnedByCoordinatorTodoID {
            EventBus.shared.publish(TadoEvent.coordinatorRejected(
                todoID: coordinatorID,
                runID: run.id,
                kind: "dispatch",
                reason: reason,
                projectName: run.project?.name
            ))
        }
        return .rejected
    }
}
