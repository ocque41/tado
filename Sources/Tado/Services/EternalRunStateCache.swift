import Foundation
import SwiftData
import Observation
import CTadoCore

/// Per-run live snapshot of Eternal state, parsed exactly once on a
/// background queue and published to SwiftUI through `@Observable`.
///
/// **Why this exists.** The four prior smooth-software passes drove
/// every spawn-side `@MainActor` blocker into detached tasks but the
/// canvas still froze on a panel-driven `tado_use_eternal_start`. The
/// remaining culprit lived on the **read** side: every two-second
/// `TimelineView` tick in `ProjectEternalSection` did three+ sync
/// `Data(contentsOf:)` + `JSONDecoder.decode` reads of `state.json`
/// (plus `String(contentsOf:)` for `metrics.jsonl`) per active run.
/// With N runs across mounted projects, each tick burned `4·N`
/// syscalls + `O(N)` decodes on the UI thread, starving the canvas
/// while the architect tile booted.
///
/// **The contract.** Views never call `EternalService.readState` or
/// `readMetrics` directly — they read `snapshot(for: runID)` from
/// this cache. The cache is fed by:
///   1. `RunEventWatcher`'s existing `FileWatcher` firings (debounced;
///      fires on every real `state.json` write).
///   2. Spawn paths priming an empty snapshot at run-create time so
///      the first render reads from cache instead of falling through
///      to nil and re-issuing a sync read.
///   3. A 10-second `.utility` background poll for any active run
///      whose snapshot is older than 10s — covers FSEvent misses
///      under APFS load.
///
/// All disk reads run inside a `Task.detached(priority: .utility)`
/// → `withCheckedContinuation { DispatchQueue.global(qos: .utility) }`
/// so @MainActor never blocks. Mutations of `snapshots` happen back
/// on @MainActor, which is the only path that fires SwiftUI
/// invalidation. SwiftData `@Model`s are not Sendable, so callers
/// pass plain run-dir paths (captured on @MainActor) into `ingest` —
/// the same `String`-path discipline used by `SpawnPrepPaths` and
/// `installHooksOffMain`.
///
/// `EternalState` is already `Codable` and value-typed, so the
/// snapshot type stays Sendable trivially.
@MainActor
@Observable
final class EternalRunStateCache {
    /// Process-wide singleton. Wired in `ContentView.onAppear` the
    /// same way `RunEventWatcher` is.
    static let shared = EternalRunStateCache()

    /// One snapshot per known run. View bodies look up by run UUID;
    /// `Equatable` conformance on the inner snapshot lets SwiftUI
    /// elide re-renders when an ingest produces an identical decode.
    private(set) var snapshots: [UUID: Snapshot] = [:]

    /// Per-run timestamp of the last successful ingest. Drives the
    /// background poll's "older than 10s" gate — we never re-read a
    /// file that the FileWatcher already touched in the last cycle.
    @ObservationIgnored
    private var lastIngestAt: [UUID: Date] = [:]

    /// Per-run dir-path snapshot captured on @MainActor at attach time.
    /// The poll iterates this map; entries are dropped when the run
    /// hits a terminal state.
    @ObservationIgnored
    private var dirPaths: [UUID: String] = [:]

    /// `true` once `start()` has been called. Prevents the poll from
    /// being spawned twice if `ContentView.onAppear` fires for a
    /// scene re-entry.
    @ObservationIgnored
    private var pollStarted: Bool = false

    private init() {}

    // MARK: - Snapshot type

    /// Sendable snapshot for one run. Mirrors the fields the view
    /// actually consumes; everything else lives in the underlying
    /// `state.json` and is read on demand by spawn paths through the
    /// existing `EternalService` helpers.
    struct Snapshot: Equatable, Sendable {
        var state: EternalState?
        var craftedExists: Bool
        var stopFlagExists: Bool
        var metricsCount: Int
        var lastMetricDisplay: String?
        var maxMetricSprint: Int

        static let empty = Snapshot(
            state: nil,
            craftedExists: false,
            stopFlagExists: false,
            metricsCount: 0,
            lastMetricDisplay: nil,
            maxMetricSprint: 0
        )
    }

    // MARK: - View read path

    /// Pure in-memory dictionary lookup. Sub-microsecond. Safe to
    /// call from any view body.
    func snapshot(for runID: UUID) -> Snapshot {
        snapshots[runID] ?? .empty
    }

    // MARK: - Attach / detach

    /// Called from `RunEventWatcher.attachEternal` once per active
    /// run. Records the dir path so the background poll can re-read
    /// it without crossing the SwiftData @Model boundary, and primes
    /// the cache with an immediate off-main read.
    func attach(runID: UUID, dirPath: String) {
        dirPaths[runID] = dirPath
        if snapshots[runID] == nil {
            snapshots[runID] = .empty
        }
        ingest(runID: runID, dirPath: dirPath)
    }

    /// Drop a run from the cache. Called when the run reaches a
    /// terminal state (the FileWatcher is also detached at this
    /// point — see `RunEventWatcher.attachEternal`).
    func detach(runID: UUID) {
        dirPaths.removeValue(forKey: runID)
        snapshots.removeValue(forKey: runID)
        lastIngestAt.removeValue(forKey: runID)
    }

    // MARK: - Ingest

    /// Reads `state.json` + `metrics.jsonl` + flag files off-main and
    /// publishes the result back on @MainActor. Multiple concurrent
    /// `ingest` calls for the same run are safe — the last write
    /// wins, and the snapshot type's `Equatable` ensures SwiftUI only
    /// invalidates on a real change.
    func ingest(runID: UUID, dirPath: String) {
        Task.detached(priority: .utility) {
            let snapshot = Self.readSnapshot(fromDirPath: dirPath)
            await MainActor.run {
                Self.shared.publish(runID: runID, snapshot: snapshot)
            }
        }
    }

    /// @MainActor publish step. Compares against the existing snapshot
    /// to avoid spurious SwiftUI invalidation; updates the
    /// last-ingested timestamp regardless so the poll sees the run as
    /// fresh.
    private func publish(runID: UUID, snapshot: Snapshot) {
        lastIngestAt[runID] = Date()
        if snapshots[runID] != snapshot {
            snapshots[runID] = snapshot
        }
    }

    // MARK: - Background poll

    /// Start the 10-second `.utility` poll. Idempotent. The poll
    /// re-ingests any run whose `lastIngestAt` is older than 10s —
    /// FSEvents under APFS load occasionally drops a write, and the
    /// architect-spawn freeze cannot be allowed to stall on a missed
    /// event. The poll runs forever on a single detached task; it
    /// hops onto @MainActor only to read the cache's two
    /// dictionaries (cheap), then back off-main for each FS read.
    func start() {
        guard !pollStarted else { return }
        pollStarted = true
        Task.detached(priority: .utility) {
            // Loop forever. There's no watchdog or retry policy here
            // (CLAUDE.md rule 1) — the loop simply re-checks every
            // 10s and re-ingests stale entries. If something throws
            // inside an ingest, that ingest fails silently and the
            // next tick tries again.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let stale = await Self.shared.runsNeedingPoll(olderThan: 10)
                for (runID, dirPath) in stale {
                    let snapshot = Self.readSnapshot(fromDirPath: dirPath)
                    await MainActor.run {
                        Self.shared.publish(runID: runID, snapshot: snapshot)
                    }
                }
            }
        }
    }

    /// Compute the set of `(runID, dirPath)` entries the poll should
    /// re-read this tick. Runs on @MainActor (cheap dictionary scan)
    /// so the poll never reaches into the cache off-main.
    fileprivate func runsNeedingPoll(olderThan seconds: TimeInterval) -> [(UUID, String)] {
        let now = Date()
        return dirPaths.compactMap { (runID, dirPath) in
            let age = lastIngestAt[runID].map { now.timeIntervalSince($0) } ?? .infinity
            return age >= seconds ? (runID, dirPath) : nil
        }
    }

    // MARK: - Off-main reader

    /// Pure-data snapshot reader. Runs on a background queue.
    /// Bundles every on-disk read for one run into one Rust FFI
    /// call (`tado_eternal_state_snapshot` — see
    /// `tado-core/crates/tado-eternal-state/`). Per CLAUDE.md rule 9
    /// (Rust-first for new non-UI logic) the parsing of state.json,
    /// metrics.jsonl, and the existence checks for crafted.md /
    /// stop-flag all happen Rust-side; Swift decodes one JSON
    /// envelope per ingest.
    ///
    /// On any FFI failure (null pointer, JSON-decode mismatch) we
    /// degrade to an `.empty` snapshot — matching the existing
    /// "missing file = empty snapshot" semantics. There's no retry
    /// here (CLAUDE.md rule 1); the next FileWatcher firing or 10s
    /// poll will try again.
    nonisolated static func readSnapshot(fromDirPath dirPath: String) -> Snapshot {
        let json: String? = dirPath.withCString { cstr -> String? in
            guard let raw = tado_eternal_state_snapshot(cstr) else { return nil }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        guard let json, let data = json.data(using: .utf8) else {
            return .empty
        }

        // Decode the structured fields with `JSONDecoder`. The
        // `last_metric_value` field's raw JSON is replayed through
        // `MetricValue` separately so the existing display
        // formatter stays the single source of truth.
        let payload = (try? JSONDecoder().decode(RustSnapshot.self, from: data)) ?? RustSnapshot.empty

        let lastMetricDisplay: String? = {
            guard let metricBytes = extractLastMetricBytes(json: data) else { return nil }
            guard let metric = try? JSONDecoder().decode(MetricValue.self, from: metricBytes)
            else { return nil }
            return metric.display
        }()

        return Snapshot(
            state: payload.state,
            craftedExists: payload.craftedExists,
            stopFlagExists: payload.stopFlagExists,
            metricsCount: payload.metricsCount,
            lastMetricDisplay: lastMetricDisplay,
            maxMetricSprint: payload.maxMetricSprint
        )
    }

    /// Pull the raw JSON bytes for `last_metric_value` out of the
    /// envelope without decoding, so we can hand them straight to
    /// `MetricValue`'s singleValue decoder. Returns nil when the
    /// field is missing / null — both shapes mean "no metric yet".
    nonisolated private static func extractLastMetricBytes(json: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: json, options: []),
              let dict = parsed as? [String: Any],
              let raw = dict["last_metric_value"],
              !(raw is NSNull)
        else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
    }

    /// Wire shape returned by `tado_eternal_state_snapshot`. Mirrors
    /// `EternalRunStateSnapshot` in the Rust crate field-for-field.
    /// `last_metric_value` is intentionally absent — it's pulled out
    /// of the raw JSON via `extractLastMetricBytes` and re-decoded
    /// through `MetricValue` so the display formatter stays
    /// single-source on Swift.
    private struct RustSnapshot: Decodable {
        let state: EternalState?
        let craftedExists: Bool
        let stopFlagExists: Bool
        let metricsCount: Int
        let maxMetricSprint: Int

        enum CodingKeys: String, CodingKey {
            case state
            case craftedExists = "crafted_exists"
            case stopFlagExists = "stop_flag_exists"
            case metricsCount = "metrics_count"
            case maxMetricSprint = "max_metric_sprint"
        }

        static let empty = RustSnapshot(
            state: nil,
            craftedExists: false,
            stopFlagExists: false,
            metricsCount: 0,
            maxMetricSprint: 0
        )
    }
}

// MARK: - Convenience

extension EternalRunStateCache.Snapshot {
    /// Mirror of `EternalService.isHookFresh` semantics, computed
    /// from the cached snapshot. Reuses `EternalService.hookLivenessThreshold`
    /// + `activeHookPhases` so a view's "running" pill flips at the
    /// exact moment the service's would have. The cache only changes
    /// the *delivery* mechanism (off-main, debounced); the predicate
    /// is the same.
    var isHookFresh: Bool {
        if stopFlagExists { return false }
        guard let state, let staleness = state.secondsSinceActivity,
              staleness < EternalService.hookLivenessThreshold
        else { return false }
        return EternalService.activeHookPhases.contains(state.phase)
    }
}
