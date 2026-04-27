import Foundation
import AppKit

enum SessionStatus: String, Equatable {
    case pending
    case running
    /// The agent has stopped writing output but no question UI is on
    /// screen — it's idling at its input prompt waiting for the next
    /// user instruction. Lower-urgency than `.awaitingResponse`.
    case needsInput
    /// The agent is actively asking the user a question / presenting a
    /// plan and awaiting an explicit response (yes/no, plan approval,
    /// numbered selection). Detected by scraping the bottom of the
    /// grid for `(y/n)` markers and plan-approval language. Higher-
    /// urgency: SystemNotifier + sound by default.
    case awaitingResponse
    case completed
    case failed
}

@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id: UUID
    let todoID: UUID
    let todoText: String
    var canvasPosition: CGPoint
    var isRunning: Bool = true
    var exitCode: Int32? = nil
    var title: String
    var gridIndex: Int
    /// Wall-clock time the session was constructed. Used by the sidebar
    /// to show live uptime. Immutable, so it can stay un-observed — the
    /// ticking clock is driven by a `TimelineView` in the consuming view.
    let startedAt: Date
    /// Observation-ignored: the activity timer mutates this every 1.5 s per
    /// session. Observing it would invalidate every tile in the canvas
    /// `ForEach` on every tick. Status transitions (which *are* observed)
    /// carry the user-visible signal.
    @ObservationIgnored var lastActivityDate: Date
    var status: SessionStatus = .running
    var promptQueue: [String] = []
    var unreadMessageCount: Int = 0
    var engine: TerminalEngine?
    var tileWidth: CGFloat = CanvasLayout.contentWidth
    var tileHeight: CGFloat = CanvasLayout.contentHeight
    var theme: TerminalTheme = .tadoDark

    /// Rust-backed PTY + VT parser. Populated by
    /// `MetalTerminalTileView.spawnIfNeeded` on the tile's first
    /// `.onAppear`; nil until the spawn completes. Observed so SwiftUI
    /// re-evaluates the tile body on the nil → Session transition —
    /// without observation, the placeholder sticks forever even after
    /// spawn succeeds. The underlying Rust grid mutates independently
    /// of SwiftUI; those changes flow through the Metal draw loop, not
    /// here.
    var coreSession: TadoCore.Session?

    /// Not rendered in any view — only consumed by ProcessSpawner/start-dir
    /// logic. Observation would be pure overhead.
    @ObservationIgnored var lastKnownCwd: String?
    /// Ring-buffered terminal output accumulated between IPC log flushes.
    /// Capped so long-running agent sessions can't leak unbounded memory; the
    /// on-disk IPC log under `/tmp/tado-ipc/sessions/<id>/log` remains the
    /// source of truth for full scrollback.
    @ObservationIgnored private(set) var logBuffer: String = ""
    /// Hard cap on in-memory log buffer before trim. 256 KB is ~4000 lines of
    /// typical agent output — more than enough between 5 s flushes.
    static let logBufferByteCap = 256 * 1024
    var projectName: String?
    var projectID: UUID?
    var agentName: String?
    var teamName: String?
    var teamID: UUID?
    var projectRoot: String?
    var teamAgents: [String]?
    /// When non-nil, overrides the settings-derived `--permission-mode …` flags
    /// for this session's spawn. Set by EternalService so an Eternal tile can
    /// launch with `--dangerously-skip-permissions` or `bypassPermissions`
    /// regardless of the project's default ClaudeMode. Read once by CanvasView
    /// at spawn time — the Metal tile has already spawned after that, so
    /// mutating this later has no effect.
    @ObservationIgnored var modeFlagsOverride: [String]?
    /// Per-session `--model <id>` override. Set by the dispatch pipeline when an
    /// agent's frontmatter pins a model (haiku/sonnet/opus). Honored by
    /// CanvasView at spawn time in place of the global AppSettings model.
    @ObservationIgnored var modelFlagsOverride: [String]?
    /// Per-session `--effort <level>` override. Pairs with modelFlagsOverride so
    /// phase agents can run Haiku at max effort or Opus at high effort without
    /// the user having to touch Settings.
    @ObservationIgnored var effortFlagsOverride: [String]?

    /// When true, this session is an Eternal worker. The exact spawn
    /// path depends on `eternalLoopKind`:
    ///   - `external` → the `.tado/eternal/hooks/eternal-loop.sh`
    ///     wrapper is launched; it respawns `claude -p` per turn.
    ///   - `internal` → `claude --permission-mode auto` is launched
    ///     directly (interactive, no wrapper). The initial eternal
    ///     prompt is fed through the PTY by Tado, and Tado's idle-
    ///     detection re-injects "continue" prompts each time the
    ///     session goes `.needsInput`.
    @ObservationIgnored var isEternalWorker: Bool = false

    /// `external` or `internal`. See `EternalRun.loopKind` doc for the
    /// behavioral split. Nil on non-eternal sessions.
    @ObservationIgnored var eternalLoopKind: String?

    /// "mega" or "sprint" — the wrapper surfaces SPRINT-DONE detection only
    /// for sprint mode. Ignored when isEternalWorker is false.
    @ObservationIgnored var eternalMode: String?

    /// Prompt the internal-mode driver re-injects every time the session
    /// goes `.needsInput`. Set at spawn time by `EternalService.spawnWorker`
    /// to something like "continue the eternal task — read crafted.md,
    /// do one more iteration, append to progress.md". Nil for external
    /// mode (the external wrapper owns its own continuation).
    @ObservationIgnored var eternalContinuePrompt: String?

    /// Tracks whether Tado has already typed `/loop <interval> …` into
    /// this session. Flipped after the first `.needsInput` transition
    /// for internal mode so the `/loop` secondary driver gets installed
    /// exactly once. The primary driver (Tado's per-idle injection)
    /// keeps firing regardless.
    @ObservationIgnored var eternalLoopCommandInstalled: Bool = false

    /// Timestamp of the most recent raw keystroke the user typed into this
    /// tile's PTY — set by `noteUserInput()` called from
    /// `MetalTerminalView.keyDown`. Used by `drainQueueIfReady` to back
    /// off idle-injection when the user is interacting with the tile.
    ///
    /// Without this cooldown, an internal-mode Eternal worker paused at
    /// a modal dialog (e.g. Ctrl+C "are you sure you want to quit?") sees
    /// Tado type `/loop …` or the continue prompt on top of the dialog
    /// every 5 s, which corrupts the dialog state and makes the terminal
    /// appear unresponsive to the user's own Enter/arrow-key presses.
    /// Once the user types, idle-injection pauses for
    /// `userInputCooldownSeconds` so the user has breathing room to
    /// finish whatever interactive flow they started.
    @ObservationIgnored var userLastTypedAt: Date?

    /// How long after the user's last keystroke idle-injection stays
    /// suspended. 60 s is generous enough to cover "user types Ctrl+C,
    /// reads a confirmation dialog, and picks an option" without
    /// permanently parking a worker.
    static let userInputCooldownSeconds: TimeInterval = 60
    /// Completion marker, e.g. "ETERNAL-DONE". The wrapper exits when a
    /// claude -p stdout emits this on its own line.
    @ObservationIgnored var eternalDoneMarker: String?
    /// Optional raw model id for `--model`, e.g. "claude-haiku-4-5". The
    /// wrapper appends `--model <id>` when set.
    @ObservationIgnored var eternalModelID: String?
    /// Optional effort level for `--effort`, e.g. "max". The wrapper
    /// appends `--effort <level>` when set.
    @ObservationIgnored var eternalEffortLevel: String?
    /// Controls whether the wrapper passes `--dangerously-skip-permissions`
    /// to each claude -p invocation. Mirrors Project.eternalSkipPermissions.
    @ObservationIgnored var eternalSkipPermissionsFlag: Bool = true

    // MARK: - Run linkage (multi-run)

    /// UUID of the `EternalRun` that owns this session, when the session is an
    /// eternal architect, worker, or interventor tile. Set by `spawnAndWire`
    /// from the spawn-time metadata; read by the hook/path-resolution code
    /// (forwarded as `TADO_ETERNAL_RUN_ID` env var to workers) and by the
    /// canvas tile header to label the tile with the run.
    ///
    /// Nil for non-eternal tiles. `dispatchRunID` is the analogous field for
    /// Dispatch phases; the two are mutually exclusive per session.
    @ObservationIgnored var eternalRunID: UUID?

    /// UUID of the `DispatchRun` that owns this session, when the session is
    /// the architect or a phase tile of a dispatch run. Mutually exclusive
    /// with `eternalRunID`.
    @ObservationIgnored var dispatchRunID: UUID?

    /// Role of this session within its owning run — `"architect"`, `"worker"`,
    /// `"interventor"`, or `"phase"`. Informational only (canvas label +
    /// session-picker heuristics); not consulted by path resolution.
    @ObservationIgnored var runRole: String?
    var onStatusChange: ((SessionStatus) -> Void)?
    var onCwdChange: ((String) -> Void)?
    var onLogFlush: ((String) -> Void)?

    func appendLog(_ text: String) {
        logBuffer.append(text)
        if logBuffer.utf8.count > Self.logBufferByteCap {
            let overflow = logBuffer.utf8.count - Self.logBufferByteCap
            let trimIndex = logBuffer.utf8.index(logBuffer.utf8.startIndex, offsetBy: overflow)
            logBuffer = String(logBuffer[trimIndex...])
        }
    }

    func drainLogBuffer() -> String {
        let chunk = logBuffer
        logBuffer = ""
        return chunk
    }

    init(todoID: UUID, todoText: String, canvasPosition: CGPoint, gridIndex: Int, engine: TerminalEngine? = nil) {
        let now = Date()
        self.id = UUID()
        self.todoID = todoID
        self.todoText = todoText
        self.canvasPosition = canvasPosition
        self.gridIndex = gridIndex
        self.title = todoText
        self.lastActivityDate = now
        self.startedAt = now
        self.engine = engine
    }

    /// Send text to the terminal followed by Enter. Runs through the
    /// Rust PTY writer; bracketed-paste framing (DECSET 2004, escape
    /// sequences `ESC [ 200 ~` / `ESC [ 201 ~`) is applied for
    /// multi-line text when the PTY has the mode enabled.
    private func sendToTerminal(_ text: String) {
        guard let core = coreSession else { return }

        if text.contains("\n"), core.bracketedPasteEnabled {
            let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
            let end:   [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
            core.write(start)
            core.write(text: text)
            core.write(end)
        } else {
            core.write(text: text)
        }

        // Scale delay based on text length: 50 ms base + 1 ms per 100
        // bytes, capped at 2 s. Matches the historical SwiftTerm cadence
        // so agents that pace on newline-arrival don't see regressions.
        let delay = min(0.05 + Double(text.utf8.count) / 100_000.0, 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.coreSession?.write(text: "\r")
        }
    }

    /// Send immediately if agent is idle, otherwise queue
    func enqueueOrSend(_ text: String) {
        if status == .needsInput || status == .awaitingResponse
            || status == .completed || status == .failed {
            sendToTerminal(text)
            markActivity()
        } else {
            promptQueue.append(text)
        }
    }

    /// Called by the activity timer — if idle and queue has items, send next.
    ///
    /// For internal-mode Eternal workers, this function also doubles as the
    /// PRIMARY continuation driver. Every time the session goes idle after
    /// the initial prompt, `drainQueueIfReady` re-fills the queue with
    /// `eternalContinuePrompt` so the next `.needsInput` has something to
    /// send. On the very first idle-after-initial-prompt (detected via
    /// `eternalLoopCommandInstalled`), it also enqueues the `/loop` command
    /// as the SECONDARY continuation driver, which Claude Code's own
    /// scheduler fires on a 30s interval for up to a week.
    ///
    /// **User-input cooldown (eternal workers only):** if the user typed
    /// into this PTY within the last `userInputCooldownSeconds`, drain is
    /// skipped entirely. Otherwise Tado's injection lands on top of
    /// whatever the user is in the middle of — a Ctrl+C confirmation
    /// dialog, a `/cost` pager, a paste in progress — and both the
    /// injected text AND the user's next keystrokes get interleaved into
    /// the TUI, which reads as "the terminal stopped responding." Non-
    /// eternal tiles don't have this problem because nothing auto-drains
    /// them; their `promptQueue` only fills via explicit
    /// `enqueueOrSend` from forward mode or IPC.
    ///
    /// **Internal-mode eternal workers also drain on `.awaitingResponse`**
    /// — defensively, in case a real selector menu / y-n prompt slips
    /// through `--permission-mode auto`. Auto mode is supposed to keep
    /// the worker out of those states, but a bespoke hook or tool
    /// could still gate one. Typing the continuation prompt over an
    /// interactive prompt is benign in auto mode (it either escapes
    /// the menu or types harmless characters), and the alternative —
    /// the worker hanging silently with a queued continuation — is
    /// the exact failure mode the dual-layer continuation was built
    /// to avoid.
    func drainQueueIfReady() {
        let canDrain: Bool
        if status == .needsInput {
            canDrain = true
        } else if status == .awaitingResponse,
                  isEternalWorker, eternalLoopKind == "internal" {
            canDrain = true
        } else {
            canDrain = false
        }
        guard canDrain, !promptQueue.isEmpty else { return }
        if userInputCooldownActive {
            return
        }
        let next = promptQueue.removeFirst()
        sendToTerminal(next)
        markActivity()
        refillQueueForInternalEternalIfNeeded()
    }

    /// True when the user has typed into this PTY recently enough that
    /// Tado should back off auto-injection. See `userLastTypedAt` doc.
    /// Only consulted for eternal-worker sessions — other tiles don't
    /// auto-drain.
    private var userInputCooldownActive: Bool {
        guard isEternalWorker,
              let typed = userLastTypedAt else { return false }
        return Date().timeIntervalSince(typed) < Self.userInputCooldownSeconds
    }

    /// Note that the user just typed a raw keystroke into this PTY.
    /// Called from `MetalTerminalView.keyDown` so auto-injection knows
    /// to yield. Does NOT call `markActivity()` — that path is for
    /// terminal OUTPUT, not user INPUT; keeping them separate lets the
    /// idle-timer still flip to `.needsInput` after claude finishes
    /// echoing, without the cooldown fighting that signal.
    func noteUserInput() {
        userLastTypedAt = Date()
    }

    /// Keep an internal-mode Eternal worker's prompt queue non-empty.
    /// Called after every successful drain.
    ///
    /// On first call post-initial-prompt: enqueue `/loop 30s <continue>`
    /// first, then the continue prompt. The `/loop` command goes out on
    /// the NEXT idle (turn 2), installing Claude Code's own scheduler.
    /// After that, every subsequent drain refills with one continue
    /// prompt so Tado's own idle injection keeps firing turn-by-turn.
    ///
    /// The two layers run in parallel: Tado's injection provides
    /// low-latency iteration (continues fire ~5s after each turn ends),
    /// and `/loop` provides resilience (continues still fire on its 30s
    /// cron even if Tado's main loop hiccups).
    private func refillQueueForInternalEternalIfNeeded() {
        guard isEternalWorker,
              eternalLoopKind == "internal",
              let continuePrompt = eternalContinuePrompt,
              !continuePrompt.isEmpty
        else { return }

        if !eternalLoopCommandInstalled {
            eternalLoopCommandInstalled = true
            // Queue the /loop command first — it'll fire on the next
            // idle transition (turn 2). Continue prompt goes second so
            // it lands on turn 3.
            promptQueue.append("/loop 30s \(continuePrompt)")
        }
        promptQueue.append(continuePrompt)
    }

    func markActivity() {
        lastActivityDate = Date()
        if status == .needsInput || status == .awaitingResponse {
            status = .running
            onStatusChange?(.running)
        }
    }

    /// Snapshot of the bottom of the grid, refreshed only when
    /// `checkIdle` has to decide between `.needsInput` and
    /// `.awaitingResponse`. Avoids re-allocating a snapshot on every
    /// idle tick: once the session has settled into a steady idle
    /// state, the cursor stops moving so the screen contents don't
    /// change either, and we already cached the answer in `status`.
    func checkIdle() {
        guard isRunning else { return }
        if Date().timeIntervalSince(lastActivityDate) > 5.0 {
            let detected: SessionStatus = isScreenAwaitingResponse()
                ? .awaitingResponse
                : .needsInput
            if status != detected {
                status = detected
                onStatusChange?(detected)
                switch detected {
                case .awaitingResponse:
                    EventBus.shared.publish(
                        .terminalAwaitingResponse(sessionID: id, title: title, projectName: projectName)
                    )
                case .needsInput:
                    EventBus.shared.publish(
                        .terminalIdle(sessionID: id, title: title, projectName: projectName)
                    )
                default:
                    break
                }
            }
            drainQueueIfReady()
        } else {
            if status != .running {
                status = .running
                onStatusChange?(.running)
            }
        }
    }

    /// Read the bottom rows of the live grid and look for markers that
    /// imply the agent is asking a question or asking the user to
    /// approve a plan. Detection is intentionally permissive — false
    /// positives just mean an extra prominent notification, while
    /// false negatives leave the user thinking nothing is asking for
    /// their attention.
    ///
    /// **Why `❯` (U+276F) is NOT a marker:** Claude Code v2.x uses
    /// that character as the always-on input prompt indicator inside
    /// its idle input box, NOT only as a selector arrow. Treating it
    /// as awaiting-response was load-bearing for one bug: it kept an
    /// internal-mode Eternal worker's `drainQueueIfReady` from ever
    /// firing the initial brief — claude booted, settled at the input
    /// prompt with `❯` showing, status flipped to `.awaitingResponse`
    /// instead of `.needsInput`, and the queued sprint/mega prompt
    /// sat there forever. Real awaiting-response cases (plan approval,
    /// y/n confirmations, numbered selectors with prose) still get
    /// caught by the markers below.
    ///
    /// Markers (any one is sufficient):
    ///   - `(y/n)`, `(Y/n)`, `(y/N)`, `[y/n]`, `(yes/no)` — generic
    ///     CLI prompts.
    ///   - `Approve plan`, `Do you want`, `Press Enter`, `Continue?`,
    ///     `(esc to`, `Approve this` — plan-approval / continuation
    ///     language emitted by both engines.
    private func isScreenAwaitingResponse() -> Bool {
        guard let core = coreSession,
              let snap = core.snapshotFull() else { return false }
        let cols = Int(snap.cols)
        let rows = Int(snap.rows)
        guard cols > 0, rows > 0,
              snap.cells.count >= cols * rows else { return false }
        // Scan up to 16 rows from the bottom — Claude's selector menus
        // routinely span ~6-10 rows; 16 covers plan approval too.
        let scanRows = min(rows, 16)
        let startRow = rows - scanRows
        var text = String()
        text.reserveCapacity(scanRows * cols + scanRows)
        for r in startRow..<rows {
            for c in 0..<cols {
                let cell = snap.cells[r * cols + c]
                if cell.ch == 0 {
                    text.append(" ")
                } else if let scalar = Unicode.Scalar(cell.ch) {
                    text.unicodeScalars.append(scalar)
                }
            }
            text.append("\n")
        }
        return Self.awaitingResponseMarkers.contains { text.contains($0) }
            || Self.awaitingResponseLowercaseMarkers.contains {
                text.lowercased().contains($0)
            }
    }

    /// Case-sensitive markers — kept separate so we don't lowercase
    /// every scan when the symbol-only markers can short-circuit.
    private static let awaitingResponseMarkers: [String] = [
        "(y/n)",
        "(Y/n)",
        "(y/N)",
        "[y/n]",
        "(yes/no)",
        "(esc to"
    ]

    /// Lowercase substring markers. The scan text is lowercased once
    /// before testing each.
    private static let awaitingResponseLowercaseMarkers: [String] = [
        "approve plan",
        "do you want",
        "press enter",
        "continue?",
        "approve this"
    ]

    func markTerminated(exitCode: Int32?) {
        self.isRunning = false
        self.exitCode = exitCode
        if let code = exitCode, code == 0 {
            status = .completed
            EventBus.shared.publish(
                .terminalCompleted(sessionID: id, title: title, projectName: projectName)
            )
        } else {
            status = .failed
            EventBus.shared.publish(
                .terminalFailed(sessionID: id, title: title, exitCode: exitCode, projectName: projectName)
            )
        }
        onStatusChange?(status)
    }
}
