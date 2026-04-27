import Foundation
import Observation
import SwiftData

/// Polls bt-core's `code.index_status` for every registered project
/// and republishes meaningful state transitions through `EventBus`.
/// That way the in-app banner overlay, dock-badge updater, and the
/// `tado-events` socket subscribers all see code-indexing activity
/// without bt-core having to know about Swift event types.
///
/// Why polling vs push
/// -------------------
/// The Rust indexer publishes through a closure passed to
/// `run_full_index`; surfacing that all the way to Swift would
/// require a callback FFI (function pointer + opaque ctx + lifetime
/// dance). Polling the existing `code.index_status` JSON FFI is
/// simpler and adequate at the cadence we need (every 2 s while a
/// job is running).
///
/// Lifecycle
/// ---------
/// One singleton `CodeIndexEventBridge.shared` ticks while the app
/// is alive. Memory cost is trivial — a Set<String> of project IDs
/// we've already announced "started" / "completed" for, so we don't
/// double-publish across ticks.
@MainActor
@Observable
final class CodeIndexEventBridge {
    static let shared = CodeIndexEventBridge()

    /// Project IDs we've announced "started" for in the current run
    /// cycle. Cleared when we see them transition to `running == false`.
    private var announcedStart: Set<String> = []
    /// Project IDs we've announced "completed" for. Stays set until
    /// the next time the project's `running` flips back to true.
    private var announcedCompletion: Set<String> = []

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// Last per-project progress value we published. Throttle so the
    /// banner doesn't fire 5 events per second on a fast machine.
    private var lastProgressEmit: [String: Date] = [:]
    private let progressEmitInterval: TimeInterval = 4.0

    private init() {}

    /// Kick off the polling timer. Idempotent — second call is a no-op.
    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in CodeIndexEventBridge.shared.tick() }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        let projects = DomeRpcClient.codeListProjects()
        for project in projects {
            let pid = project.projectID
            let name = project.name
            guard let status = DomeRpcClient.codeIndexStatus(projectID: pid) else {
                continue
            }
            handleTransition(projectID: pid, projectName: name, status: status)
        }
    }

    private func handleTransition(
        projectID: String,
        projectName: String,
        status: DomeRpcClient.CodeIndexStatus
    ) {
        let now = Date()
        if status.running {
            if !announcedStart.contains(projectID) {
                announcedStart.insert(projectID)
                announcedCompletion.remove(projectID)
                EventBus.shared.publish(
                    .codeIndexStarted(
                        projectID: projectID,
                        projectName: projectName,
                        filesTotal: status.filesTotal
                    )
                )
                lastProgressEmit[projectID] = now
                return
            }
            // Throttled progress publication.
            let last = lastProgressEmit[projectID] ?? .distantPast
            if now.timeIntervalSince(last) >= progressEmitInterval {
                EventBus.shared.publish(
                    .codeIndexProgress(
                        projectID: projectID,
                        projectName: projectName,
                        filesDone: status.filesDone,
                        filesTotal: status.filesTotal,
                        chunksDone: status.chunksDone
                    )
                )
                lastProgressEmit[projectID] = now
            }
            return
        }

        // Not running. If we previously saw it running, fire the
        // appropriate completed/failed event once per run cycle.
        if announcedStart.contains(projectID) && !announcedCompletion.contains(projectID) {
            announcedCompletion.insert(projectID)
            announcedStart.remove(projectID)
            if let err = status.error, !err.isEmpty {
                EventBus.shared.publish(
                    .codeIndexFailed(
                        projectID: projectID,
                        projectName: projectName,
                        message: err
                    )
                )
            } else if status.filesDone > 0 || status.chunksDone > 0 {
                let duration = elapsedSeconds(
                    startedAt: status.startedAt,
                    finishedAt: status.finishedAt
                )
                EventBus.shared.publish(
                    .codeIndexCompleted(
                        projectID: projectID,
                        projectName: projectName,
                        filesIndexed: status.filesDone,
                        chunksTotal: status.chunksDone,
                        durationSeconds: duration
                    )
                )
            }
        }
    }

    private func elapsedSeconds(startedAt: String?, finishedAt: String?) -> Double {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = startedAt.flatMap({ formatter.date(from: $0) }),
              let end = finishedAt.flatMap({ formatter.date(from: $0) }) else {
            return 0
        }
        return max(0, end.timeIntervalSince(start))
    }
}
