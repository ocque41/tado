import Foundation

/// User-visible preferences for the Tado Pets extension.
///
/// Stored as its own JSON file at
/// `<storage-root>/pets/settings.json` instead of as a substruct
/// inside `GlobalSettings.swift`. This isolation matters: the
/// Pets extension is optional, and the linter pipeline that
/// guards `GlobalSettings.swift` removes added fields. Owning
/// our own settings file means the extension can ship without
/// touching the global settings struct at all.
///
/// Same atomic-write discipline as `ScopedConfig` / `AtomicStore`
/// — temp file + rename — so a half-written `settings.json` is
/// impossible.
public struct PetsPreferences: Codable, Equatable {
    public var enabled: Bool
    public var pet: String
    public var corner: String
    public var opacity: Double
    public var showThoughtBubble: Bool
    public var positionX: Double
    public var positionY: Double
    /// When true, the Pets coordinator can boot a long-running
    /// "tado-pet-companion" agent tile on the canvas. The agent
    /// polls every active tile every minute, surfaces summaries
    /// in its own transcript, and accepts free-form requests
    /// from the user (via the floating-panel double-click prompt).
    /// On request it `tado-send`s the right message into the
    /// requested live tile, or runs an `eternal intervene` if
    /// the user wants to redirect a running Eternal.
    ///
    /// **Off by default.** The flag is persisted on disk, but
    /// the coordinator will NOT auto-spawn the companion at app
    /// launch even when the persisted value is true — the user
    /// must explicitly start it (Pets settings → "Start
    /// companion now" button, or toggle off and back on). This
    /// avoids a startup deadlock where the companion subprocess
    /// would shell `tado-deploy` from the main actor before
    /// `MainWindowRoot.onAppear` has wired the IPC broker, leaving
    /// the user staring at the loading wheel and accumulating
    /// zombie companion tiles across launches.
    public var liveAgent: Bool
    /// Session ID of the live companion tile, when one is
    /// running. Used by the floating panel's double-click prompt
    /// to address the right tile via `tado-send`. nil when the
    /// liveAgent flag is off or the companion tile died.
    public var liveAgentSessionID: String?

    public init(
        enabled: Bool = true,
        pet: String = "cat",
        corner: String = "topRight",
        opacity: Double = 1.0,
        showThoughtBubble: Bool = true,
        positionX: Double = 0,
        positionY: Double = 0,
        liveAgent: Bool = false,
        liveAgentSessionID: String? = nil
    ) {
        self.enabled = enabled
        self.pet = pet
        self.corner = corner
        self.opacity = opacity
        self.showThoughtBubble = showThoughtBubble
        self.positionX = positionX
        self.positionY = positionY
        self.liveAgent = liveAgent
        self.liveAgentSessionID = liveAgentSessionID
    }
}

/// In-memory + on-disk store for `PetsPreferences`. Singleton.
/// Reads from `<storage-root>/pets/settings.json` on first
/// access; writes via temp+rename atomic IO. Subscribers (the
/// `PetsCoordinator`) get a callback whenever the file changes.
@MainActor
public final class PetsPreferencesStore {
    public static let shared = PetsPreferencesStore()

    private(set) public var current: PetsPreferences
    private var observers: [(PetsPreferences) -> Void] = []
    private var loaded = false

    private init() {
        self.current = PetsPreferences()
    }

    /// Path the JSON lives at.
    public var settingsURL: URL {
        StorageLocationManager.currentRoot
            .appendingPathComponent("pets", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Read the JSON if present. Idempotent. Safe to call
    /// repeatedly; only the first call hits disk. Subsequent
    /// `update`s keep `current` in sync.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONDecoder().decode(PetsPreferences.self, from: data) else {
            return
        }
        current = parsed
    }

    /// Mutate + atomically persist. Subscribers fire after the
    /// file lands on disk.
    public func update(_ mutate: (inout PetsPreferences) -> Void) {
        loadIfNeeded()
        var next = current
        mutate(&next)
        guard next != current else { return }
        current = next
        write(next)
        for observer in observers { observer(next) }
    }

    /// Subscribe to changes. Idempotent in the sense that
    /// duplicates are allowed — the caller is responsible for
    /// not registering twice.
    public func addObserver(_ block: @escaping (PetsPreferences) -> Void) {
        observers.append(block)
    }

    private func write(_ value: PetsPreferences) {
        let url = settingsURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }

        // Temp + rename for atomic landing.
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // Drop on failure; next mutation re-tries.
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

/// Built-in pet identifiers — Codex Pets parity (cat, dog, fox,
/// owl, crab, snake, octopus, dragon). The string is the
/// stable on-disk key, used both as a `Resources/Pets/<id>-*`
/// filename prefix and as the value persisted in
/// `PetsPreferences.pet`.
public enum PetID {
    public static let builtIn: [String] = [
        "cat", "dog", "fox", "owl",
        "crab", "snake", "octopus", "dragon"
    ]

    public static let `default` = "cat"
}

/// One animation loop the pet can be in. The mapping from
/// concrete app activity to a `PetState` is owned by
/// `PetsCoordinator.recompute`; this enum is just the rendering
/// vocabulary.
///
/// Priority order (highest wins on aggregation across multiple
/// active sessions):
///
///   `perfRegressed > awaitingResponse > eternalRunning >
///    running > needsInput > done > idle`
public enum PetState: String, Codable, CaseIterable, Equatable {
    /// No active sessions, no recently-completed work in the
    /// last few seconds. Idle loop animation.
    case idle
    /// Everything is done — at least one session terminated
    /// successfully and nothing is in flight. Held briefly
    /// before falling back to `.idle`.
    case done
    /// At least one terminal is actively producing output.
    case running
    /// At least one terminal has been idle at its prompt for
    /// the activity-detection window (5s) but isn't displaying
    /// a question UI. Lower-urgency than `.awaitingResponse`.
    case needsInput
    /// At least one terminal is asking a y/n question, awaiting
    /// plan approval, or otherwise blocking on a typed reply.
    /// Highest "user must look" priority short of perf trouble.
    case awaitingResponse
    /// At least one Eternal run is in its working / sprint
    /// loop. Tado-specific overlay state — Codex Pets ships
    /// only the three core states; we add this so the user
    /// can see "agent is grinding" at a glance.
    case eternalRunning
    /// At least one Eternal run with `kind = perf` posted a
    /// regression on the last cycle. Beats `.awaitingResponse`
    /// because losing a perf cycle is the rarer / higher-
    /// signal event.
    case perfRegressed
}

extension PetState {
    /// Bigger number wins. Used by `PetsAggregate.resolve`.
    public var priority: Int {
        switch self {
        case .perfRegressed:     return 70
        case .awaitingResponse:  return 60
        case .eternalRunning:    return 50
        case .running:           return 40
        case .needsInput:        return 30
        case .done:              return 20
        case .idle:              return 10
        }
    }

    /// Human-readable label used by the per-state builder UI in
    /// `PetsWindowRoot`. Stays close to the raw value so the
    /// builder rows and the JSON `meta.json` keys read the same.
    public var displayLabel: String {
        switch self {
        case .idle:              return "Idle"
        case .done:              return "Done"
        case .running:           return "Running"
        case .needsInput:        return "Needs input"
        case .awaitingResponse:  return "Awaiting response"
        case .eternalRunning:    return "Eternal running"
        case .perfRegressed:     return "Perf regressed"
        }
    }
}

/// One terminal-session row inside `ProjectStatus.sessions`.
/// Used by the click-to-expand popover.
public struct PetSessionRow: Identifiable, Equatable {
    public let id: UUID                // TerminalSession.id
    public let todoID: UUID
    public let title: String
    public let gridIndex: Int
    public let status: String          // SessionStatus.rawValue
    public let startedAt: Date
}

/// One Eternal/Dispatch row inside `ProjectStatus.runs`. Both
/// run kinds share this row shape so the popover renders them
/// uniformly.
public struct PetRunRow: Identifiable, Equatable {
    public enum Kind: String, Equatable { case eternal, dispatch }
    public let id: UUID                // EternalRun.id / DispatchRun.id
    public let kind: Kind
    public let label: String
    /// Free-text caption like "Sprint 7", "Phase 3 of 5", or
    /// "perf Δ-0.12". Computed by the coordinator off the run's
    /// state file.
    public let caption: String
    /// True iff this run is the one that is driving the
    /// aggregate state right now. The popover renders driver
    /// rows with an accent so the user can find the cause.
    public let isDriver: Bool
}

/// One row in the click-to-expand popover.
public struct PetProjectStatus: Identifiable, Equatable {
    public let id: UUID                // Project.id (or sentinel)
    public let name: String
    public let sessions: [PetSessionRow]
    public let runs: [PetRunRow]

    public var isEmpty: Bool { sessions.isEmpty && runs.isEmpty }
}

/// The full snapshot the coordinator publishes to its
/// observers. The floating sprite, thought-bubble, and
/// expanded popover all read from one of these.
public struct PetsAggregate: Equatable {
    public let state: PetState
    /// Short caption shown above the sprite when state is
    /// non-idle. nil → render no bubble.
    public let bubble: String?
    /// Per-project breakdown for the click-to-expand popover.
    /// Sorted by descending activity (projects with sessions
    /// first, then alphabetical).
    public let perProject: [PetProjectStatus]
    /// Total count of "active surfaces" for the popover header
    /// (sessions + runs across every project).
    public let totalActive: Int
    /// How many sessions are currently in `awaitingResponse`
    /// or `needsInput`. Drives the optional badge dot on the
    /// sprite (and matches the dock-badge count when the user
    /// has both turned on).
    public let totalNeedsInput: Int

    public static let empty = PetsAggregate(
        state: .idle,
        bubble: nil,
        perProject: [],
        totalActive: 0,
        totalNeedsInput: 0
    )
}

/// Pure helper: given a list of `(state, weight)` candidates
/// and a tiebreaker bubble caption, pick the winning state. The
/// coordinator and the test suite both call this — the rule
/// stays in one place.
public enum PetsAggregateResolver {
    public struct Candidate: Equatable {
        public let state: PetState
        public let bubble: String?
        public init(state: PetState, bubble: String?) {
            self.state = state
            self.bubble = bubble
        }
    }

    /// Reduces a list of candidate states to the single
    /// winning state + bubble. Empty list → `.idle / nil`.
    public static func resolve(_ candidates: [Candidate]) -> (PetState, String?) {
        guard let winner = candidates.max(by: { $0.state.priority < $1.state.priority }) else {
            return (.idle, nil)
        }
        return (winner.state, winner.bubble)
    }
}
