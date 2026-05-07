import Foundation
import SwiftData

/// Coordinator-driven extensions on `EternalService`. These mirror
/// the existing UI-driven entry points (modal → spawnArchitect →
/// CraftedReviewModal → acceptReview → spawnWorker) but accept
/// arguments from the Unix-socket router rather than from SwiftUI.
///
/// Three new methods land here:
///   - `proposeViaCoordinator` — build a new `EternalRun`, mark it
///     coordinator-spawned, call `spawnArchitect`. Idempotent on
///     `coordinatorTodoID`: if a run for this exact coordinator
///     todo already exists, return it instead of creating a
///     duplicate.
///   - `acceptReviewWithGuard` — optimistic-concurrency wrapper
///     around the existing `acceptReview`. Returns
///     `.stateMismatch(actual)` when the run has moved off
///     `awaitingReview` (e.g. the human hit Accept first); writes
///     the coordinator's review note to disk before spawning the
///     worker.
///   - `rejectReview` — archive the existing `crafted.md` to a
///     timestamped sidecar, optionally overwrite `user-brief.md`
///     with a refined brief, transition state back to `planning`,
///     and re-invoke `spawnArchitect`.
extension EternalService {

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

    static func reviewNoteFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("review-note.md")
    }

    static func rejectedCraftedArchiveURL(_ run: EternalRun, timestamp: Date = Date()) -> URL {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let stamp = fmt.string(from: timestamp)
            .replacingOccurrences(of: ":", with: "-")
        return eternalRoot(run)
            .appendingPathComponent("rejected-crafted-\(stamp).md")
    }

    /// Create a new `EternalRun` for the given project, brief, and
    /// mode and immediately drive the architect. Used by
    /// `tado-eternal propose` (CLI) and the coordinator agent.
    @MainActor
    @discardableResult
    static func proposeViaCoordinator(
        project: Project,
        label: String,
        userBrief: String,
        mode: String,
        engine: String,
        coordinatorTodoID: UUID,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> EternalRun {
        // Idempotency: if the same coordinator already proposed a
        // run that's still drafted/planning/awaitingReview, hand
        // back the existing one instead of forking a second tree.
        // Coordinator restarts (e.g. retry after a transient CLI
        // failure) MUST converge on the same run id.
        let descriptor = FetchDescriptor<EternalRun>()
        if let existing = (try? modelContext.fetch(descriptor))?.first(where: { run in
            run.spawnedByCoordinatorTodoID == coordinatorTodoID
                && (run.state == "drafted"
                    || run.state == "planning"
                    || run.state == "awaitingReview"
                    || run.state == "ready")
        }) {
            return existing
        }

        let normalizedMode = (mode == "sprint") ? "sprint" : "mega"
        let normalizedEngine: String = {
            if engine == "codex" { return "codex" }
            return "claude"
        }()
        let resolvedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? EternalRun.defaultLabel(mode: normalizedMode)
            : label

        let run = EternalRun(
            project: project,
            label: resolvedLabel,
            mode: normalizedMode,
            engine: normalizedEngine,
            userBrief: userBrief
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
            kind: "eternal.\(run.mode)",
            projectName: project.name
        ))
        return run
    }

    /// Optimistic-concurrency wrapper around `acceptReview`.
    /// Returns `stateMismatch(actual)` when the run is not in
    /// `awaitingReview` (e.g. the human modal accepted first).
    /// Persists `reviewNote` to `<run-dir>/review-note.md`
    /// regardless of outcome — even on mismatch the coordinator's
    /// rationale is preserved alongside the human acceptance for
    /// audit.
    @MainActor
    @discardableResult
    static func acceptReviewWithGuard(
        run: EternalRun,
        expectedState: String,
        reviewNote: String?,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> AcceptResult {
        if let note = reviewNote, !note.isEmpty {
            // Off-main: capture the run-root + note-file paths as plain
            // Strings, write the markdown asynchronously. The audit
            // record is read by humans long after the spawn completes;
            // a tens-of-ms late arrival is harmless.
            let runRootPath = eternalRoot(run).path
            let notePath = reviewNoteFileURL(run).path
            let noteBytes = note
            Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.createDirectory(
                    atPath: runRootPath,
                    withIntermediateDirectories: true
                )
                try? noteBytes.write(
                    toFile: notePath,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        if run.state != expectedState {
            return .stateMismatch(actual: run.state)
        }

        acceptReview(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        if let coordinatorID = run.spawnedByCoordinatorTodoID {
            EventBus.shared.publish(TadoEvent.coordinatorAccepted(
                todoID: coordinatorID,
                runID: run.id,
                kind: "eternal.\(run.mode)",
                projectName: run.project?.name
            ))
        }
        return .accepted
    }

    /// Reject the architect's `crafted.md`. Archives the existing
    /// crafted file to a timestamped sidecar so the rejection is
    /// auditable, optionally replaces `user-brief.md` with the
    /// coordinator's refined brief, transitions the run back to
    /// `planning`, and re-spawns the architect.
    @MainActor
    @discardableResult
    static func rejectReview(
        run: EternalRun,
        reason: String,
        rebrief: String?,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> RejectResult {
        if run.state != "awaitingReview" && run.state != "ready" {
            return .stateMismatch(actual: run.state)
        }

        // Archive crafted.md to a timestamped sidecar before we
        // overwrite anything. The archive doubles as a record of
        // what the coordinator (or human) chose to reject — never
        // silently lose work.
        //
        // Off-main: the crafted body can be multi-KB and the archive
        // write is durable IO; reading + writing on @MainActor would
        // freeze the panel for the duration of the disk round-trip.
        // The sidecar is read by humans during audit, never by the
        // architect re-spawn — a late arrival is fine.
        let craftedPath = craftedFileURL(run).path
        let archivePath = rejectedCraftedArchiveURL(run).path
        let archiveReason = reason
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: craftedPath) else { return }
            let header = "<!-- rejected: \(archiveReason) -->\n\n".data(using: .utf8) ?? Data()
            let archiveURL = URL(fileURLWithPath: archivePath)
            if let body = try? Data(contentsOf: URL(fileURLWithPath: craftedPath)) {
                try? (header + body).write(to: archiveURL)
            } else {
                try? header.write(to: archiveURL)
            }
        }

        // Refined brief, if supplied, overwrites user-brief.md so
        // the next architect run reads the new direction. Update the
        // SwiftData @Model on @MainActor (cheap) and hop the actual
        // file write to a detached task — `spawnArchitect` (called
        // immediately below) will also write the brief from `run.userBrief`
        // off-main via `resetAndWriteBriefOffMain`, so the path
        // converges either way.
        if let rebrief, !rebrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            run.userBrief = rebrief
            let briefPath = userBriefFileURL(run).path
            let briefBytes = rebrief
            Task.detached(priority: .userInitiated) {
                try? briefBytes.write(
                    toFile: briefPath,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        // resetEternal wipes crafted.md + the worker-side state
        // files; the architect re-spawn writes user-brief.md
        // again from run.userBrief. State flips to "planning"
        // inside spawnArchitect.
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
                kind: "eternal.\(run.mode)",
                reason: reason,
                projectName: run.project?.name
            ))
        }
        return .rejected
    }
}
