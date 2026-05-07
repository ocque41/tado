import Foundation
import AppKit
import SwiftUI
import SwiftData
import Observation

/// Observable hub that owns Tado Pets at runtime: the floating
/// `NSPanel`, the current `PetsAggregate`, the event-bus
/// subscription, and the cached pointer back to `TerminalManager`
/// for active-session enumeration.
///
/// Single instance for the whole app (`PetsCoordinator.shared`).
/// Created lazily so unit tests can build their own.
///
/// Subscriptions
/// - **EventBus** — every `terminal.*` / `eternal.*` /
///   `dispatch.*` event triggers a debounced recompute (~250 ms)
///   so a burst of events during a sprint doesn't churn the
///   sprite cross-fade.
/// - **TerminalManager.sessions** — read directly when computing
///   the aggregate. Not a publish/subscribe — we re-poll the
///   array each recompute pass since the events tell us *when*
///   to look, and events fire on every status change.
/// - **NSApplication.didBecomeActiveNotification** — clears the
///   "needs input" badge when the user focuses Tado, mirroring
///   the dock-badge pattern from
///   `DockBadgeUpdater.install()`.
///
/// Lifecycle
/// - `PetsExtension.onAppLaunch` calls
///   `installFloatingPanelIfEnabled()` after settings load.
/// - `bind(terminalManager:modelContainer:)` is called by
///   `MainWindowRoot.onAppear` (where the manager exists in
///   scope). After that the coordinator can read sessions and
///   query SwiftData for runs.
@MainActor
@Observable
public final class PetsCoordinator {
    public static let shared = PetsCoordinator()

    // MARK: - Public observable state

    /// Latest aggregate. Floating-panel content view re-renders
    /// when this changes.
    public private(set) var aggregate: PetsAggregate = .empty

    /// Whether the floating panel is on screen. Toggled by
    /// `/pet`, by the settings window, or by `Tuck Away` /
    /// `Wake` in the popover footer.
    public private(set) var isVisible: Bool = false

    /// Snapshot of the user-visible Pets settings. Re-populated
    /// every time the underlying `GlobalSettings.pets` changes
    /// (via Settings sheet, `/pet` slash command, the Pets
    /// settings window, or external `tado-config` write). The
    /// floating panel root view observes this directly so the
    /// pet sprite, opacity, thought-bubble visibility, and
    /// active pet ID all update without a relaunch.
    ///
    /// Internal because `PetsPreferences` is the extension's own
    /// settings type — the floating-panel SwiftUI view inside
    /// the Pets module is the only consumer.
    private(set) var petSettings: PetsPreferences = PetsPreferences()

    /// Active hatch sheet binding — set by the slash-command
    /// handler and the settings window's "Hatch new pet" button;
    /// observed by `PetsHatchSheet` for presentation. Becomes
    /// `nil` when the sheet dismisses.
    public var pendingHatch: PetsHatchRequest?

    // MARK: - Private state

    @ObservationIgnored private var panel: PetsFloatingPanelController?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private weak var terminalManager: TerminalManager?
    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var installedEventDeliverer = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var settingsObserverInstalled = false
    /// Held momentarily after a session reaches `.completed` /
    /// `.failed` so the pet can show the "done" state for a
    /// breath. Sentinel that decays to `.idle` after ~6 s of
    /// no other activity.
    @ObservationIgnored private var lastTerminalCompletedAt: Date?

    // MARK: - Lifecycle

    private init() {}

    /// Wire long-lived observers. Idempotent. Call from
    /// `PetsExtension.onAppLaunch`.
    public func bootstrap() {
        installEventDelivererIfNeeded()
        installActivationObserverIfNeeded()
        installSettingsObserverIfNeeded()
        applySettings(initial: true)
    }

    /// Hand the coordinator a live `TerminalManager` so it can
    /// enumerate sessions when computing aggregates. The
    /// reference is weak — the manager owns its own lifetime.
    func bind(terminalManager: TerminalManager, modelContainer: ModelContainer? = nil) {
        self.terminalManager = terminalManager
        if let mc = modelContainer {
            self.modelContainer = mc
        }
        scheduleRecompute()
    }

    // MARK: - Visibility control

    /// Slash-command + popover-footer toggle. Persists the new
    /// state into `PetsPreferences.enabled` so the choice
    /// survives relaunch.
    public func toggleVisible() {
        let nextEnabled = !isVisible
        PetsPreferencesStore.shared.update { $0.enabled = nextEnabled }
        // PetsPreferencesStore notifies subscribers synchronously,
        // which routes through installSettingsObserverIfNeeded →
        // applySettings(initial:false) and refreshes petSettings +
        // the panel visibility.
    }

    public func openHatchSheet(prefilled: String) {
        pendingHatch = PetsHatchRequest(
            id: UUID(),
            prompt: prefilled
        )
    }

    public func dismissHatchSheet() {
        pendingHatch = nil
    }

    // MARK: - Settings

    private func applySettings(initial: Bool) {
        PetsPreferencesStore.shared.loadIfNeeded()
        let pets = PetsPreferencesStore.shared.current
        let prev = petSettings
        if pets != petSettings {
            petSettings = pets
        }
        applyEnabled(pets.enabled)
        if initial {
            // Pre-warm the cache for the picked pet so the first
            // sprite swap is instantaneous.
            PetSpriteCache.shared.preheat(petID: pets.pet)
            // The persisted `liveAgentSessionID` always points at
            // a dead tile after relaunch (the prior process is
            // gone), so clear it. The double-click "send to
            // companion" prompt and the settings-window status
            // line both read this field; without the clear, the
            // UI would advertise a session that doesn't exist.
            if pets.liveAgentSessionID != nil {
                PetsPreferencesStore.shared.update {
                    $0.liveAgentSessionID = nil
                }
            }
        }
        // If the corner changed and we have no explicit drag-saved
        // position, snap the panel to the new corner. (Drag-saved
        // positions take precedence — the user's last-known place
        // wins over a corner picker change.)
        if pets.corner != prev.corner, pets.positionX == 0, pets.positionY == 0 {
            panel?.reposition()
        }
        // If the active pet changed, evict the previous pet's
        // sprite cache lazily and pre-warm the new one so the
        // first cross-fade after the picker doesn't take a hit.
        if pets.pet != prev.pet {
            PetSpriteCache.shared.evict(petID: prev.pet)
            PetSpriteCache.shared.preheat(petID: pets.pet)
        }
        // Live-agent companion: spawn / shut down a tile based
        // on the toggle. Only fires on a USER-DRIVEN transition.
        // Initial settings load NEVER auto-spawns even when the
        // persisted flag is on — the user has to explicitly start
        // it from the Pets settings window after the app is fully
        // booted. Without this gate, every cold launch with the
        // flag persisted-on would shell `tado-deploy` from the
        // main actor before the IPC broker is wired in
        // `MainWindowRoot.onAppear`, pinning the UI on the
        // loading wheel and leaving zombie companion tiles from
        // prior launches (the dedup guard in
        // `spawnLiveCompanionIfNeeded` reads
        // `terminalManager.sessions`, which is empty at this
        // point).
        if !initial, pets.liveAgent != prev.liveAgent {
            if pets.liveAgent {
                spawnLiveCompanionIfNeeded()
            } else {
                stopLiveCompanionIfNeeded()
            }
        }
    }

    // MARK: - Live companion agent

    /// Boot the long-running companion tile via the tado-deploy
    /// CLI. The agent uses the `tado-pet-companion` definition
    /// at `.claude/agents/tado-pet-companion.md` and the
    /// matching skill — it polls every active tile every 60 s,
    /// surfaces summaries in its own transcript, and accepts
    /// free-form prompts from the user via `tado-send`.
    @ObservationIgnored private var companionSpawnInFlight = false

    /// Public so the Pets settings window's "Start companion now"
    /// button can call it directly. Idempotent — repeated calls
    /// while a spawn is already in flight are no-ops, and an
    /// already-running companion tile short-circuits the spawn.
    public func spawnLiveCompanionIfNeeded() {
        guard !companionSpawnInFlight else { return }

        // Don't re-spawn if we still have a live tile from the
        // last toggle.
        if let savedID = PetsPreferencesStore.shared.current.liveAgentSessionID,
           let uuid = UUID(uuidString: savedID),
           let manager = terminalManager,
           manager.sessions.contains(where: { $0.id == uuid && $0.isRunning }) {
            return
        }

        companionSpawnInFlight = true

        let prompt = """
        You are the tado-pet-companion agent. Run the
        tado-pet-companion skill end-to-end.

        Mission: every 60 seconds, run `tado-list` and
        summarise what every active session is doing. When the
        user sends you a message via `tado-send`, parse it as
        an instruction (intervene on a session, send a prompt
        to a session, query state) and act on it. Loop forever
        until the user terminates this tile.

        First action: print a one-line "tado-pet-companion
        online" banner and emit a `tado-notify` so the user
        sees the boot in the in-app banner. Then drop into the
        poll loop.
        """

        let deployPath = NSHomeDirectory() + "/.local/bin/tado-deploy"
        // Pin the companion's working dir to ~/Documents so its
        // shell, file lookups, and any logs it writes land in
        // the user's Documents tree, not /Users/<user>.
        // ~/Documents is a stable, sandboxed-friendly default for
        // a forever-living tile that may run for hours.
        let companionCwd = NSHomeDirectory() + "/Documents"

        // Run the subprocess launch off the main actor. `task.run()`
        // does fork + exec + pipe wiring synchronously, and the
        // shelled tado-deploy itself cold-starts python3 (200-800ms
        // on macOS) — pinning the main thread for that long is what
        // made the toggle feel like a hang.
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: deployPath)
            task.arguments = [
                prompt,
                "--agent", "tado-pet-companion",
                "--engine", "claude",
                "--cwd", companionCwd
            ]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                // tado-deploy prints the new session UUID to stdout
                // — read it back, persist to settings so the
                // double-click prompt can address the right tile.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
                let extractedID: String? = text.range(of: uuidPattern, options: .regularExpression)
                    .map { String(text[$0]) }
                await MainActor.run {
                    if let id = extractedID {
                        PetsPreferencesStore.shared.update {
                            $0.liveAgentSessionID = id
                        }
                    }
                    PetsCoordinator.shared.companionSpawnInFlight = false
                }
            } catch {
                // Surface a one-line in-app banner so the user
                // notices the spawn failed (no path, missing CLI).
                let errorMessage = error.localizedDescription
                await MainActor.run {
                    EventBus.shared.publish(
                        TadoEvent(
                            type: "user.broadcast",
                            severity: .error,
                            source: .system,
                            title: "Pet companion failed to spawn",
                            body: "tado-deploy could not start: \(errorMessage)"
                        )
                    )
                    PetsCoordinator.shared.companionSpawnInFlight = false
                }
            }
        }
    }

    private func stopLiveCompanionIfNeeded() {
        guard let savedID = PetsPreferencesStore.shared.current.liveAgentSessionID,
              let uuid = UUID(uuidString: savedID) else { return }
        // Send a graceful stop message to the companion. It's a
        // long-running tile — we don't kill the PTY here; the
        // user can still close the tile from the canvas if they
        // want it gone immediately.
        terminalManager?.forwardInput(
            toTodoID: uuid,
            text: "tado-pet-companion: shutdown requested by user. Print a goodbye line and exit."
        )
        PetsPreferencesStore.shared.update { $0.liveAgentSessionID = nil }
    }

    /// Public hook the floating panel uses on double-click.
    /// Sends the user's free-form text to the live companion
    /// tile (if any), or surfaces a notice if liveAgent isn't on.
    public func sendToLiveCompanion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let savedID = PetsPreferencesStore.shared.current.liveAgentSessionID,
              let uuid = UUID(uuidString: savedID) else {
            EventBus.shared.publish(
                TadoEvent(
                    type: "user.broadcast",
                    severity: .warning,
                    source: .system,
                    title: "Live agent not running",
                    body: "Turn on Live agent in Pets settings to address the companion."
                )
            )
            return
        }
        terminalManager?.forwardInput(toTodoID: uuid, text: trimmed)
    }

    private func applyEnabled(_ enabled: Bool) {
        if enabled {
            installFloatingPanelIfNeeded()
            isVisible = true
        } else {
            panel?.hide()
            isVisible = false
        }
    }

    private func installFloatingPanelIfNeeded() {
        if panel == nil {
            panel = PetsFloatingPanelController(coordinator: self)
        }
        panel?.show()
    }

    // MARK: - Recompute pipeline

    /// Public entry-point for "something might have changed,
    /// please recompute soon." Coalesces bursts via a 250 ms
    /// trailing debounce.
    public func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.recomputeNow()
        }
    }

    /// Synchronous recompute — used by tests and by the
    /// activation hook (when we want immediate clear, not a
    /// debounced one).
    public func recomputeNow() {
        let snapshot = collectSnapshot()
        let next = Self.buildAggregate(from: snapshot)
        if next != aggregate {
            aggregate = next
        }
    }

    // MARK: - Snapshot collection

    fileprivate struct Snapshot {
        let sessions: [TerminalSession]
        let eternalRuns: [EternalRunSummary]
        let dispatchRuns: [DispatchRunSummary]
        let recentTerminalCompletedAt: Date?
        let now: Date
    }

    private func collectSnapshot() -> Snapshot {
        let sessions = terminalManager?.sessions ?? []
        let eternal = collectEternalSummaries()
        let dispatch = collectDispatchSummaries()
        return Snapshot(
            sessions: sessions,
            eternalRuns: eternal,
            dispatchRuns: dispatch,
            recentTerminalCompletedAt: lastTerminalCompletedAt,
            now: Date()
        )
    }

    private func collectEternalSummaries() -> [EternalRunSummary] {
        guard let mc = modelContainer else { return [] }
        let context = ModelContext(mc)
        let descriptor = FetchDescriptor<EternalRun>(
            predicate: #Predicate { $0.archivedAt == nil }
        )
        guard let runs = try? context.fetch(descriptor) else { return [] }
        // Only count an Eternal as "active" in the popover when
        // there's a live tile backing it. `state: planning` /
        // `ready` without a running architect or worker tile is
        // a *zombie* row — the SwiftData record persisted but the
        // tile died, so the user should see "no active surfaces"
        // rather than a misleading run header. Two checks per
        // run: (a) state is `running` (already meaningful), or
        // (b) the workerTodoID / architectTodoID resolves to a
        // currently-running TerminalSession.
        let liveTodoIDs = Set(
            (terminalManager?.sessions ?? [])
                .filter { $0.isRunning }
                .map { $0.todoID }
        )
        return runs.compactMap { run in
            let workerLive: Bool = {
                if let id = run.workerTodoID, liveTodoIDs.contains(id) { return true }
                if let id = run.architectTodoID, liveTodoIDs.contains(id) { return true }
                return false
            }()
            let isStateActive = run.state == "running"
            guard isStateActive || workerLive else { return nil }
            let stateOnDisk = readEternalState(forRunID: run.id)
            return EternalRunSummary(
                id: run.id,
                projectID: run.project?.id,
                projectName: run.project?.name ?? "(no project)",
                label: run.label,
                kind: run.kind,
                phase: stateOnDisk?.phase ?? "working",
                sprints: stateOnDisk?.sprints ?? 0,
                perfRegressionDelta: stateOnDisk?.perfRegressionDelta,
                lastPerfScore: stateOnDisk?.lastPerfScore
            )
        }
    }

    private func collectDispatchSummaries() -> [DispatchRunSummary] {
        guard let mc = modelContainer else { return [] }
        let context = ModelContext(mc)
        let descriptor = FetchDescriptor<DispatchRun>(
            predicate: #Predicate { $0.archivedAt == nil }
        )
        guard let runs = try? context.fetch(descriptor) else { return [] }
        let liveTodoIDs = Set(
            (terminalManager?.sessions ?? [])
                .filter { $0.isRunning }
                .map { $0.todoID }
        )
        return runs.compactMap { run in
            let live: Bool = {
                if run.state == "dispatching" { return true }
                if let id = run.architectTodoID, liveTodoIDs.contains(id) { return true }
                if let id = run.currentPhaseTodoID, liveTodoIDs.contains(id) { return true }
                return false
            }()
            guard live else { return nil }
            return DispatchRunSummary(
                id: run.id,
                projectID: run.project?.id,
                projectName: run.project?.name ?? "(no project)",
                label: run.label
            )
        }
    }

    private func readEternalState(forRunID runID: UUID) -> EternalState? {
        // EternalRun's per-run state.json sits inside the
        // owning project's `.tado/eternal/runs/<id>/state.json`.
        // We don't have a non-SwiftData way to find the project
        // root from the coordinator without re-querying; the
        // RunEventWatcher already plumbs that path for events.
        // For aggregate purposes we only need the projection
        // that *emits* into events — coordinator falls back to
        // event-driven counters. Returning nil here is fine;
        // `buildAggregate` derives state from session activity
        // when the run state is missing.
        return nil
    }

    // MARK: - Pure aggregate builder (testable)

    /// Pure function — given a snapshot, what aggregate should
    /// the pet show? Owned at the type level so unit tests can
    /// drive synthetic snapshots.
    fileprivate static func buildAggregate(from snap: Snapshot) -> PetsAggregate {
        var candidates: [PetsAggregateResolver.Candidate] = []
        var perProject: [UUID: ProjectAccumulator] = [:]
        var totalActive = 0
        var totalNeedsInput = 0

        // 1. Terminal sessions — the bread-and-butter.
        for session in snap.sessions {
            guard session.isRunning else { continue }
            totalActive += 1
            let row = PetSessionRow(
                id: session.id,
                todoID: session.todoID,
                title: session.title,
                gridIndex: session.gridIndex,
                status: session.status.rawValue,
                startedAt: session.startedAt
            )
            let projectID = session.projectID ?? AnonymousProject.id
            let projectName = session.projectName ?? AnonymousProject.name
            perProject[projectID, default: ProjectAccumulator(name: projectName)]
                .sessions.append(row)

            switch session.status {
            case .awaitingResponse:
                totalNeedsInput += 1
                candidates.append(.init(
                    state: .awaitingResponse,
                    bubble: "Awaiting reply — \(session.title)"
                ))
            case .needsInput:
                totalNeedsInput += 1
                candidates.append(.init(
                    state: .needsInput,
                    bubble: "Idle — \(session.title)"
                ))
            case .running:
                candidates.append(.init(
                    state: .running,
                    bubble: session.title
                ))
            case .pending, .completed, .failed:
                break
            }
        }

        // 2. Eternal runs — perf regressions outrank everything.
        for run in snap.eternalRuns {
            totalActive += 1
            let driverDelta = run.perfRegressionDelta
            let isPerfRegressed = driverDelta != nil
            let caption: String
            if let delta = driverDelta {
                caption = String(format: "perf Δ%.2f", delta)
            } else if run.kind == "perf", let composite = run.lastPerfScore {
                caption = String(format: "Sprint %d · perf %.2f", run.sprints, composite)
            } else {
                caption = "Sprint \(run.sprints)"
            }
            let row = PetRunRow(
                id: run.id,
                kind: .eternal,
                label: "Eternal \(run.label)",
                caption: caption,
                isDriver: isPerfRegressed || run.phase == "working"
            )
            let projectID = run.projectID ?? AnonymousProject.id
            perProject[projectID, default: ProjectAccumulator(name: run.projectName)]
                .runs.append(row)

            if isPerfRegressed {
                candidates.append(.init(
                    state: .perfRegressed,
                    bubble: "Perf regression — \(run.label)"
                ))
            } else if run.phase == "working" {
                candidates.append(.init(
                    state: .eternalRunning,
                    bubble: "Sprint \(run.sprints) — \(run.label)"
                ))
            }
        }

        // 3. Dispatch runs — informational, do not move the
        // sprite state on their own (the dispatched tiles
        // already show up as terminal sessions, which is what
        // drives state). They appear in the popover so the
        // user can see what's pending.
        for run in snap.dispatchRuns {
            totalActive += 1
            let row = PetRunRow(
                id: run.id,
                kind: .dispatch,
                label: "Dispatch \(run.label)",
                caption: "in flight",
                isDriver: false
            )
            let projectID = run.projectID ?? AnonymousProject.id
            perProject[projectID, default: ProjectAccumulator(name: run.projectName)]
                .runs.append(row)
        }

        // 4. Resolve to one state. If nothing is active but a
        // session completed within the recent-completion window
        // we hold `.done` so the user gets the finished signal;
        // after that we fall to `.idle`.
        if candidates.isEmpty {
            if let completed = snap.recentTerminalCompletedAt,
               snap.now.timeIntervalSince(completed) < 6 {
                candidates.append(.init(state: .done, bubble: "Done"))
            }
        }

        let (state, bubble) = PetsAggregateResolver.resolve(candidates)

        // Sort projects: ones that drive the chosen state first,
        // then by descending count, then alphabetical.
        let projects: [PetProjectStatus] = perProject
            .map { (id, acc) in
                PetProjectStatus(
                    id: id,
                    name: acc.name,
                    sessions: acc.sessions.sorted { $0.gridIndex < $1.gridIndex },
                    runs: acc.runs
                )
            }
            .sorted {
                if $0.sessions.count != $1.sessions.count {
                    return $0.sessions.count > $1.sessions.count
                }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }

        return PetsAggregate(
            state: state,
            bubble: bubble,
            perProject: projects,
            totalActive: totalActive,
            totalNeedsInput: totalNeedsInput
        )
    }

    private struct ProjectAccumulator {
        var name: String
        var sessions: [PetSessionRow] = []
        var runs: [PetRunRow] = []
    }

    /// Sentinel project rows for sessions / runs whose
    /// `Project` association is nil (coordinator tiles, etc).
    private enum AnonymousProject {
        static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        static let name = "(no project)"
    }

    // MARK: - EventBus subscription

    private func installEventDelivererIfNeeded() {
        guard !installedEventDeliverer else { return }
        installedEventDeliverer = true
        EventBus.shared.addDeliverer { [weak self] event in
            guard let self else { return }
            // Only the events we actually care about. Filtering
            // here keeps the closure cheap on every publish; the
            // dock-badge deliverer uses a similar pattern.
            switch event.type {
            case "terminal.spawned",
                 "terminal.idle",
                 "terminal.awaitingResponse",
                 "terminal.completed",
                 "terminal.failed",
                 "eternal.phaseCompleted",
                 "eternal.runCompleted",
                 "eternal.runStopped",
                 "eternal.runFailed",
                 "eternal.workerWedged",
                 "eternal.perfImproved",
                 "eternal.perfHeld",
                 "eternal.perfRegressed",
                 "dispatch.phaseCompleted",
                 "dispatch.runCompleted":
                if event.type == "terminal.completed" || event.type == "terminal.failed" {
                    self.lastTerminalCompletedAt = Date()
                }
                self.scheduleRecompute()
            default:
                break
            }
        }
    }

    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Activate-on-focus parity with DockBadgeUpdater:
            // when the user comes back to Tado, give the panel a
            // synchronous nudge so any catch-up state lands fast.
            Task { @MainActor in
                self?.recomputeNow()
            }
        }
    }

    private func installSettingsObserverIfNeeded() {
        guard !settingsObserverInstalled else { return }
        settingsObserverInstalled = true
        PetsPreferencesStore.shared.addObserver { [weak self] _ in
            Task { @MainActor in
                self?.applySettings(initial: false)
                self?.scheduleRecompute()
            }
        }
    }

    deinit {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: - Run summaries

struct EternalRunSummary {
    let id: UUID
    let projectID: UUID?
    let projectName: String
    let label: String
    let kind: String
    let phase: String
    let sprints: Int
    let perfRegressionDelta: Double?
    let lastPerfScore: Double?
}

struct DispatchRunSummary {
    let id: UUID
    let projectID: UUID?
    let projectName: String
    let label: String
}

// MARK: - Hatch request envelope

public struct PetsHatchRequest: Identifiable, Equatable {
    public let id: UUID
    public var prompt: String
}

