import Foundation
import SwiftData

// MARK: - Pure state machine

/// One periodic observation of a dispatch plan's on-disk state. The
/// watchdog feeds these into `WatchdogState.consume(tick:)` to decide
/// whether the chain is making progress, is done, or is stuck.
struct WatchdogTick: Equatable {
    let now: Date
    /// Highest `order` value among phase JSONs whose `status` is
    /// `completed`. `0` means no phase has completed yet.
    let highestCompletedOrder: Int
    /// Highest `order` value found across all phase files, regardless
    /// of status. Tells the watchdog how many phases exist without
    /// having to re-read plan.json.
    let totalPhases: Int
}

/// Outcome of feeding a tick into `WatchdogState`.
enum WatchdogOutcome: Equatable {
    /// Chain is progressing (or still within the stall timeout).
    case running
    /// All phases are `completed`. The watchdog should stop; the
    /// project stays in `dispatching` until the architect gets the
    /// final tado-send.
    case completed
    /// No progress observed for at least `timeout` seconds. Integer
    /// payload is the phase order the watchdog believes is stuck —
    /// one past the last completed phase.
    case stalled(atPhase: Int)
}

/// Pure state the watchdog carries across ticks. Extracted from the
/// timer-driven class so the stall detection can be unit-tested
/// without SwiftData, Timer, or a filesystem.
struct WatchdogState: Equatable {
    let timeout: TimeInterval
    private(set) var lastAdvanceAt: Date
    private(set) var lastObservedCompleted: Int
    private(set) var totalPhases: Int

    init(startedAt: Date, timeout: TimeInterval, totalPhases: Int) {
        self.lastAdvanceAt = startedAt
        self.lastObservedCompleted = 0
        self.totalPhases = totalPhases
        self.timeout = timeout
    }

    /// Consume one observation. Updates `lastAdvanceAt` whenever the
    /// observed completion count advances so a phase that takes 19
    /// minutes doesn't falsely trip a 20-minute timeout.
    mutating func consume(tick: WatchdogTick) -> WatchdogOutcome {
        // Architect may still be writing phase files when the watchdog
        // starts, so totalPhases can grow. Never shrink it — that
        // would mask a deleted-mid-run plan as "done".
        totalPhases = max(totalPhases, tick.totalPhases)

        if tick.highestCompletedOrder > lastObservedCompleted {
            lastObservedCompleted = tick.highestCompletedOrder
            lastAdvanceAt = tick.now
        }

        if totalPhases > 0, lastObservedCompleted >= totalPhases {
            return .completed
        }

        if tick.now.timeIntervalSince(lastAdvanceAt) >= timeout {
            return .stalled(atPhase: lastObservedCompleted + 1)
        }

        return .running
    }
}

// MARK: - Timer-driven wrapper

/// Watches a single project's dispatch plan. Reads
/// `.tado/dispatch/phases/*.json` on a 30-second cadence and feeds
/// the observations into a `WatchdogState`. On stall, flips
/// `project.dispatchState` to `"stalled"`, populates `stalledAtPhase`,
/// and appends a line to `.tado/dispatch/watchdog.log`.
///
/// Not persistent across app restarts — if the user kills Tado mid-
/// dispatch, the watchdog is gone and has to be manually re-armed by
/// clicking Start (or Resume, on a stalled project).
@MainActor
final class DispatchChainWatchdog {
    /// How often the timer fires. 30s is a good balance: short enough
    /// that the UI feels responsive when a stall is caught, long
    /// enough that we're not hammering the filesystem.
    static let tickInterval: TimeInterval = 30

    private let projectID: UUID
    private let rootPath: String
    private let totalPhasesHint: Int
    private let modelContext: ModelContext
    private var state: WatchdogState
    private var timer: Timer?
    /// Clock injection — defaults to `Date.init`, override in tests so
    /// we can advance without waiting 20 real minutes.
    private let clock: () -> Date

    init(
        project: Project,
        totalPhases: Int,
        timeoutMinutes: Int,
        modelContext: ModelContext,
        clock: @escaping () -> Date = Date.init
    ) {
        self.projectID = project.id
        self.rootPath = project.rootPath
        self.totalPhasesHint = totalPhases
        self.modelContext = modelContext
        self.clock = clock
        self.state = WatchdogState(
            startedAt: clock(),
            timeout: TimeInterval(timeoutMinutes * 60),
            totalPhases: totalPhases
        )
    }

    /// Start the timer. Safe to call repeatedly — previous timer
    /// invalidates before a new one arms.
    func start() {
        stop()
        let t = Timer.scheduledTimer(
            withTimeInterval: DispatchChainWatchdog.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = t
    }

    /// Stop the timer. Idempotent.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Public entry point for a single tick — used by tests to drive
    /// the state machine without waiting for the Timer.
    func tick() {
        let observation = currentObservation()
        let outcome = state.consume(tick: observation)
        switch outcome {
        case .running:
            return
        case .completed:
            stop()
        case .stalled(let atPhase):
            recordStall(atPhase: atPhase)
            stop()
        }
    }

    /// Read all phase JSONs under `<rootPath>/.tado/dispatch/phases/`
    /// and derive the current tick. Missing directory → zero progress
    /// (matches "architect still writing the plan" state).
    private func currentObservation() -> WatchdogTick {
        let fm = FileManager.default
        let phasesDir = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(".tado/dispatch/phases")
        guard let files = try? fm.contentsOfDirectory(
            at: phasesDir,
            includingPropertiesForKeys: nil
        ) else {
            return WatchdogTick(
                now: clock(),
                highestCompletedOrder: 0,
                totalPhases: totalPhasesHint
            )
        }
        let decoder = JSONDecoder()
        var highestCompleted = 0
        var highestAny = 0
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let phase = try? decoder.decode(PhaseJSON.self, from: data) else {
                continue
            }
            highestAny = max(highestAny, phase.order)
            if phase.status == "completed" {
                highestCompleted = max(highestCompleted, phase.order)
            }
        }
        return WatchdogTick(
            now: clock(),
            highestCompletedOrder: highestCompleted,
            totalPhases: max(highestAny, totalPhasesHint)
        )
    }

    private func recordStall(atPhase: Int) {
        let project = fetchProject()
        project?.dispatchState = "stalled"
        project?.stalledAtPhase = atPhase
        try? modelContext.save()

        let timestamp = ISO8601DateFormatter().string(from: clock())
        let line = "[\(timestamp)] stall at phase \(atPhase); last advance at \(state.lastAdvanceAt); observed \(state.lastObservedCompleted)/\(state.totalPhases) completed\n"
        let logURL = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(".tado/dispatch/watchdog.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func fetchProject() -> Project? {
        let targetID = projectID
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate<Project> { $0.id == targetID }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

// MARK: - Registry

/// Tracks the live watchdog for each project. One watchdog per
/// project — `register` kills any previous watchdog for that project
/// before installing the new one, so starting a fresh plan on a
/// previously-stalled project does the right thing.
@MainActor
enum DispatchWatchdogRegistry {
    private static var active: [UUID: DispatchChainWatchdog] = [:]

    static func register(_ watchdog: DispatchChainWatchdog, for projectID: UUID) {
        active[projectID]?.stop()
        active[projectID] = watchdog
        watchdog.start()
    }

    static func stop(projectID: UUID) {
        active[projectID]?.stop()
        active.removeValue(forKey: projectID)
    }

    static func isActive(projectID: UUID) -> Bool {
        active[projectID] != nil
    }
}
