import Foundation
import SwiftData
import Observation

/// Per-run live snapshot of Dispatch state, mirroring
/// `EternalRunStateCache` for the smaller dispatch surface.
///
/// Same rationale: `ProjectDispatchSection.effectiveState` was
/// calling `DispatchPlanService.planExistsOnDisk` +
/// `craftedExistsOnDisk` synchronously on @MainActor inside the
/// section's tick. The fan-out is smaller than Eternal's (no
/// state.json + metrics.jsonl chain) but the discipline is the
/// same — view bodies must read from a pre-populated cache, never
/// from the FS directly.
///
/// Snapshots carry only the two booleans the view consumes; this
/// keeps the cache cheap to ingest under FSEvent storms.
@MainActor
@Observable
final class DispatchRunStateCache {
    static let shared = DispatchRunStateCache()

    private(set) var snapshots: [UUID: Snapshot] = [:]

    @ObservationIgnored
    private var lastIngestAt: [UUID: Date] = [:]

    @ObservationIgnored
    private var dirPaths: [UUID: String] = [:]

    @ObservationIgnored
    private var pollStarted: Bool = false

    private init() {}

    struct Snapshot: Equatable, Sendable {
        var planExists: Bool
        var craftedExists: Bool
        var phaseFileCount: Int

        static let empty = Snapshot(
            planExists: false,
            craftedExists: false,
            phaseFileCount: 0
        )
    }

    func snapshot(for runID: UUID) -> Snapshot {
        snapshots[runID] ?? .empty
    }

    func attach(runID: UUID, dirPath: String) {
        dirPaths[runID] = dirPath
        if snapshots[runID] == nil {
            snapshots[runID] = .empty
        }
        ingest(runID: runID, dirPath: dirPath)
    }

    func detach(runID: UUID) {
        dirPaths.removeValue(forKey: runID)
        snapshots.removeValue(forKey: runID)
        lastIngestAt.removeValue(forKey: runID)
    }

    func ingest(runID: UUID, dirPath: String) {
        Task.detached(priority: .utility) {
            let snapshot = Self.readSnapshot(fromDirPath: dirPath)
            await MainActor.run {
                Self.shared.publish(runID: runID, snapshot: snapshot)
            }
        }
    }

    private func publish(runID: UUID, snapshot: Snapshot) {
        lastIngestAt[runID] = Date()
        if snapshots[runID] != snapshot {
            snapshots[runID] = snapshot
        }
    }

    func start() {
        guard !pollStarted else { return }
        pollStarted = true
        Task.detached(priority: .utility) {
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

    fileprivate func runsNeedingPoll(olderThan seconds: TimeInterval) -> [(UUID, String)] {
        let now = Date()
        return dirPaths.compactMap { (runID, dirPath) in
            let age = lastIngestAt[runID].map { now.timeIntervalSince($0) } ?? .infinity
            return age >= seconds ? (runID, dirPath) : nil
        }
    }

    nonisolated static func readSnapshot(fromDirPath dirPath: String) -> Snapshot {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dirPath)
        let planURL = root.appendingPathComponent("plan.json")
        let craftedURL = root.appendingPathComponent("crafted.md")
        let phasesDir = root.appendingPathComponent("phases")

        let planExists = fm.fileExists(atPath: planURL.path)
        let craftedExists = fm.fileExists(atPath: craftedURL.path)
        var phaseFileCount = 0
        if let entries = try? fm.contentsOfDirectory(at: phasesDir, includingPropertiesForKeys: nil) {
            phaseFileCount = entries.filter { $0.pathExtension == "json" }.count
        }
        return Snapshot(
            planExists: planExists,
            craftedExists: craftedExists,
            phaseFileCount: phaseFileCount
        )
    }
}
