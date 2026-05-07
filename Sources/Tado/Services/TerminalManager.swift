import Foundation
import SwiftUI

@Observable
@MainActor
final class TerminalManager {
    var sessions: [TerminalSession] = []
    var ipcBroker: IPCBroker?
    /// Mirrored from AppSettings.randomTileColor by ContentView. When true, every new
    /// session gets a random TerminalTheme; otherwise sessions use `defaultTheme`.
    var randomTileColors: Bool = true
    /// Theme used when `randomTileColors` is false. Mirrored from
    /// AppSettings.defaultThemeId by ContentView. Lets users pin a specific
    /// background/foreground without giving up full random rotation.
    var defaultTheme: TerminalTheme = .tadoDark
    /// Theme picked for the most recently spawned session — used to avoid back-to-back
    /// repeats when randomTileColors is on.
    private var lastTheme: TerminalTheme?

    func spawnSession(
        todoID: UUID,
        todoText: String,
        canvasPosition: CGPoint,
        gridIndex: Int,
        engine: TerminalEngine? = nil,
        modeFlagsOverride: [String]? = nil,
        modelFlagsOverride: [String]? = nil,
        effortFlagsOverride: [String]? = nil,
        isEternalWorker: Bool = false,
        eternalLoopKind: String? = nil,
        eternalMode: String? = nil,
        eternalDoneMarker: String? = nil,
        eternalModelID: String? = nil,
        eternalEffortLevel: String? = nil,
        eternalSkipPermissionsFlag: Bool = true,
        eternalContinuePrompt: String? = nil,
        eternalCodexPreFlags: [String]? = nil,
        eternalCodexPostFlags: [String]? = nil,
        eternalUseCodexExec: Bool = false,
        eternalKind: String? = nil,
        eternalRunID: UUID? = nil,
        dispatchRunID: UUID? = nil,
        runRole: String? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            todoID: todoID,
            todoText: todoText,
            canvasPosition: canvasPosition,
            gridIndex: gridIndex,
            engine: engine
        )
        if randomTileColors {
            let theme = TerminalTheme.random(excluding: lastTheme)
            session.theme = theme
            lastTheme = theme
        } else {
            session.theme = defaultTheme
        }
        // Stash the overrides BEFORE appending so the canvas re-renders with
        // the final values — without this, SwiftUI could observe the new
        // session and ask for mode/model/effort flags while overrides are
        // still nil, defeating the override and letting the global AppSettings
        // drive the spawn (which is how Eternal's "Full Auto" toggle was
        // silently ignored on first render). See EternalService.spawnEternal.
        session.modeFlagsOverride = modeFlagsOverride
        session.modelFlagsOverride = modelFlagsOverride
        session.effortFlagsOverride = effortFlagsOverride
        session.isEternalWorker = isEternalWorker
        session.eternalLoopKind = eternalLoopKind
        session.eternalMode = eternalMode
        session.eternalContinuePrompt = eternalContinuePrompt
        session.eternalDoneMarker = eternalDoneMarker
        session.eternalModelID = eternalModelID
        session.eternalEffortLevel = eternalEffortLevel
        session.eternalSkipPermissionsFlag = eternalSkipPermissionsFlag
        session.eternalCodexPreFlags = eternalCodexPreFlags
        session.eternalCodexPostFlags = eternalCodexPostFlags
        session.eternalUseCodexExec = eternalUseCodexExec
        session.eternalKind = eternalKind
        session.eternalRunID = eternalRunID
        session.dispatchRunID = dispatchRunID
        session.runRole = runRole
        sessions.append(session)
        if let engine = engine {
            ipcBroker?.registerSession(session, engine: engine)
        }
        return session
    }

    /// Stop a tile's PTY process and drop the session from the manager.
    ///
    /// Sends SIGTERM by default (polite — bash wrappers run their trap
    /// handlers, claude has a chance to flush state). Pass `hard: true`
    /// to send SIGKILL instead, for cases where the process is being
    /// torn down alongside on-disk state (e.g. `deleteRun` needs the
    /// process dead NOW so file handles release before the run dir is
    /// removed).
    ///
    /// **Why not a PTY Ctrl+C write**: an interactive TUI like the
    /// `claude` CLI in auto mode installs a SIGINT handler that shows
    /// an "Are you sure you want to quit?" dialog instead of exiting.
    /// The dialog kept the process alive with open file descriptors
    /// into the Eternal run dir, which then failed `removeItem` during
    /// delete. Signalling the kernel directly via `TadoCore.Session.kill`
    /// bypasses the termios line discipline so the TUI's handler never
    /// runs.
    func terminateSession(_ id: UUID, hard: Bool = false) {
        if let session = sessions.first(where: { $0.id == id }) {
            session.coreSession?.kill(signal: hard ? SIGKILL : SIGTERM)
            session.isRunning = false
            ipcBroker?.unregisterSession(id)
        }
        sessions.removeAll { $0.id == id }
    }

    func terminateSessionForTodo(_ todoID: UUID, hard: Bool = false) {
        if let session = sessions.first(where: { $0.todoID == todoID }) {
            session.coreSession?.kill(signal: hard ? SIGKILL : SIGTERM)
            session.isRunning = false
            ipcBroker?.unregisterSession(session.id)
            sessions.removeAll { $0.id == session.id }
        }
    }

    /// Hard-kill every running PTY tile child immediately. Wired to
    /// `NSApplication.willTerminateNotification` from `TadoApp.init`
    /// so Cmd+Q doesn't leave orphan agent CLIs (claude / codex) and
    /// their MCP bridges running invisibly in the background.
    ///
    /// Pre-v0.18 Cmd+Q only ran `DomeRpcClient.domeStop()` plus the
    /// `BackgroundLifecycle` teardown — neither touched
    /// `TerminalManager`, so any tile process the user hadn't
    /// individually stopped survived as an orphan re-parented to
    /// launchd. Combined with the now-fixed process-group kill in
    /// `Session::kill`, this finally guarantees that every descendant
    /// of every tile dies with the app.
    ///
    /// SIGKILL (not SIGTERM) is correct here: the app is exiting in
    /// the next few hundred milliseconds, so giving children a chance
    /// to flush state is moot — the kernel reclaim is faster and
    /// surer than a SIGTERM-then-wait dance, and rule 1 (no
    /// watchdogs / timeouts on dispatch) forbids the wait anyway.
    func shutdownAllSessions() {
        for session in sessions {
            session.coreSession?.kill(signal: SIGKILL)
            session.isRunning = false
            ipcBroker?.unregisterSession(session.id)
        }
        sessions.removeAll()
    }

    func session(forTodoID todoID: UUID) -> TerminalSession? {
        sessions.first { $0.todoID == todoID }
    }

    func forwardInput(toTodoID todoID: UUID, text: String) {
        guard let session = sessions.first(where: { $0.todoID == todoID }) else { return }
        session.enqueueOrSend(text)
    }

    func spawnAndWire(
        todo: TodoItem,
        engine: TerminalEngine,
        cwd: String? = nil,
        agentName: String? = nil,
        projectName: String? = nil,
        teamName: String? = nil,
        teamID: UUID? = nil,
        teamAgents: [String]? = nil,
        modeFlagsOverride: [String]? = nil,
        modelFlagsOverride: [String]? = nil,
        effortFlagsOverride: [String]? = nil,
        isEternalWorker: Bool = false,
        eternalLoopKind: String? = nil,
        eternalMode: String? = nil,
        eternalDoneMarker: String? = nil,
        eternalModelID: String? = nil,
        eternalEffortLevel: String? = nil,
        eternalSkipPermissionsFlag: Bool = true,
        eternalContinuePrompt: String? = nil,
        eternalCodexPreFlags: [String]? = nil,
        eternalCodexPostFlags: [String]? = nil,
        eternalUseCodexExec: Bool = false,
        eternalKind: String? = nil,
        eternalRunID: UUID? = nil,
        dispatchRunID: UUID? = nil,
        runRole: String? = nil
    ) {
        let session = spawnSession(
            todoID: todo.id,
            todoText: todo.text,
            canvasPosition: todo.canvasPosition,
            gridIndex: todo.gridIndex,
            engine: engine,
            modeFlagsOverride: modeFlagsOverride,
            modelFlagsOverride: modelFlagsOverride,
            effortFlagsOverride: effortFlagsOverride,
            isEternalWorker: isEternalWorker,
            eternalLoopKind: eternalLoopKind,
            eternalMode: eternalMode,
            eternalDoneMarker: eternalDoneMarker,
            eternalModelID: eternalModelID,
            eternalEffortLevel: eternalEffortLevel,
            eternalSkipPermissionsFlag: eternalSkipPermissionsFlag,
            eternalContinuePrompt: eternalContinuePrompt,
            eternalCodexPreFlags: eternalCodexPreFlags,
            eternalCodexPostFlags: eternalCodexPostFlags,
            eternalUseCodexExec: eternalUseCodexExec,
            eternalKind: eternalKind,
            eternalRunID: eternalRunID,
            dispatchRunID: dispatchRunID,
            runRole: runRole
        )
        if let cwd { session.lastKnownCwd = cwd }
        session.agentName = agentName
        session.projectName = projectName
        session.projectID = todo.projectID
        session.teamName = teamName
        session.teamID = teamID
        session.projectRoot = cwd
        session.teamAgents = teamAgents
        // Rehydrate the persisted tile size from the todo so a manual
        // resize survives quit + relaunch. Pre-v0.18 todos default to
        // CanvasLayout.contentWidth/Height via SwiftData lightweight
        // migration, so this is a no-op for them.
        session.tileWidth = todo.tileWidth
        session.tileHeight = todo.tileHeight
        todo.terminalSessionID = session.id
        todo.status = .running

        session.onStatusChange = { [weak todo] newStatus in
            todo?.status = newStatus
        }
        session.onCwdChange = { [weak todo] dir in
            todo?.cwd = dir
        }
        session.onLogFlush = { [weak todo] chunk in
            guard let todo else { return }
            todo.terminalLog.append(chunk)
            if todo.terminalLog.count > TodoItem.maxLogSize {
                todo.terminalLog.removeFirst(todo.terminalLog.count - TodoItem.maxLogSize)
            }
        }

        // Capture the original spawn shape so the fallback ladder can
        // re-spawn with adjusted overrides. Weak `todo` so a deleted
        // todo collapses the closure to a no-op rather than retaining
        // the SwiftData object past its lifecycle.
        session.onSpawnRejected = { [weak self, weak todo] dead in
            guard let self, let todo else { return }
            self.applySpawnFallback(
                deadSession: dead,
                todo: todo,
                originalEngine: engine,
                cwd: cwd,
                agentName: agentName,
                projectName: projectName,
                teamName: teamName,
                teamID: teamID,
                teamAgents: teamAgents
            )
        }

        // Internal-mode Eternal workers: the PTY launches interactive
        // `claude --permission-mode auto` with NO `-p` argument, so the
        // initial bootstrap brief (`todo.text` — the full sprint/mega
        // prompt produced by `ProcessSpawner.eternalSprintPrompt` /
        // `eternalMegaPrompt`) is NOT delivered by the command line.
        // Instead we seed the session's prompt queue here so the first
        // `.needsInput` transition (fired by `TerminalSession.checkIdle`
        // after claude's TUI has been cursor-still for ~5 s at its `›`
        // prompt) drains the brief into the PTY as if the user typed it.
        //
        // After that first drain, `refillQueueForInternalEternalIfNeeded`
        // takes over — it installs `/loop 30s <continue>` as the
        // secondary driver on turn 2 and keeps appending a `<continue>`
        // nudge after every drain so Tado's idle-injection primary
        // driver always has something to send.
        //
        // External mode does NOT need this seed because its wrapper
        // (`eternal-loop.sh`) re-invokes `claude -p "<brief>"` per turn,
        // with the brief baked into the shell command.
        if isEternalWorker && eternalLoopKind == "internal" {
            session.promptQueue.append(todo.text)
        }
    }

    /// Per-tile fallback ladder. Fires once when a non-Eternal-worker
    /// tile dies with a CLI-rejection signature (set on the session by
    /// `TerminalSession.detectSpawnRejection` during `markTerminated`).
    /// Mutates the session's overrides — or, in the engine-step rung,
    /// flips the spawn engine — and re-spawns through the same
    /// `spawnAndWire` path so all the live wiring (IPC registration,
    /// callbacks, theme, eternal flags) reattaches identically.
    ///
    /// The ladder steps in dependency order, picking the first rung
    /// applicable to the rejection kind:
    ///
    ///   1. **Limit** — strip the rejected effort/extra flag entirely.
    ///   2. **Mode** — fall back along `ClaudeMode.nextFallback` /
    ///      `CodexMode.nextFallback`.
    ///   3. **Model** — fall back along `ClaudeModel.nextFallback` /
    ///      `CodexModel.nextFallback`.
    ///   4. **Engine** — Codex → Claude (only direction we ever swap).
    ///
    /// Each ladder firing is one-shot per session
    /// (`session.fallbackAttempted`); a respawned tile that ALSO dies
    /// surfaces normally as `terminalFailed` without triggering another
    /// respawn. This keeps the ladder bounded by construction without
    /// any timer/watchdog (CLAUDE.md rule 1).
    func applySpawnFallback(
        deadSession: TerminalSession,
        todo: TodoItem,
        originalEngine: TerminalEngine,
        cwd: String?,
        agentName: String?,
        projectName: String?,
        teamName: String?,
        teamID: UUID?,
        teamAgents: [String]?
    ) {
        guard deadSession.isEligibleForSpawnFallback else { return }
        guard let kind = deadSession.spawnRejection else { return }
        // One-shot guard set BEFORE any decisions so a re-entrant call
        // from the same termination cannot double-fire.
        deadSession.fallbackAttempted = true

        // Snapshot the dead session's per-tile overrides as a baseline;
        // the rung-specific code mutates these and threads them into
        // the respawn.
        var modeOverride = deadSession.modeFlagsOverride ?? deadSession.engine.flatMap { eng in
            switch eng {
            case .claude: return ClaudeMode.askPermissions.cliFlags
            case .codex:  return CodexMode.defaultPermissions.cliFlags
            }
        } ?? []
        var effortOverride = deadSession.effortFlagsOverride ?? []
        var modelOverride = deadSession.modelFlagsOverride ?? []
        var engineOverride: TerminalEngine = originalEngine

        var rungFrom = "original config"
        var rungTo = "original config"
        let reason: String
        switch kind {
        case .invalidEnumValue:
            reason = "CLI rejected an enum value (limit step)"
        case .unknownFlag:
            reason = "CLI rejected an unknown flag (limit step)"
        case .modelNotFound:
            reason = "CLI rejected the model id (model step)"
        }

        // Rung 1 — Limit step. Drop effort entirely. Cheapest, most
        // common cause of CLI rejection (auto-effort drift, removed
        // enum values).
        if case .invalidEnumValue = kind, !effortOverride.isEmpty {
            rungFrom = "effort=\(effortOverride.last ?? "?")"
            rungTo = "no --effort"
            effortOverride = []
        } else if case .unknownFlag = kind, !effortOverride.isEmpty {
            rungFrom = "effort=\(effortOverride.last ?? "?")"
            rungTo = "no --effort"
            effortOverride = []
        }
        // Rung 2 — Mode step. Honor the picker's curated chain from
        // ClaudeMode.nextFallback / CodexMode.nextFallback. Only step
        // here if rung 1 didn't already make a change (so we don't
        // double-step on a single ladder firing).
        else if originalEngine == .claude,
                let currentMode = parseClaudeMode(from: modeOverride),
                let next = currentMode.nextFallback() {
            rungFrom = "mode=\(currentMode.rawValue)"
            rungTo = "mode=\(next.rawValue)"
            modeOverride = next.cliFlags
        } else if originalEngine == .codex,
                  let currentMode = parseCodexMode(from: modeOverride),
                  let next = currentMode.nextFallback() {
            rungFrom = "mode=\(currentMode.rawValue)"
            rungTo = "mode=\(next.rawValue)"
            modeOverride = next.cliFlags
        }

        // Rung 3 — Model step. Triggered explicitly when the CLI told
        // us the model id is unknown.
        if case .modelNotFound = kind {
            if originalEngine == .claude,
               let currentModel = parseClaudeModel(from: modelOverride),
               let next = currentModel.nextFallback() {
                rungFrom = "model=\(currentModel.rawValue)"
                rungTo = "model=\(next.rawValue)"
                modelOverride = next.cliFlags
            } else if originalEngine == .codex,
                      let currentModel = parseCodexModel(from: modelOverride),
                      let next = currentModel.nextFallback() {
                rungFrom = "model=\(currentModel.rawValue)"
                rungTo = "model=\(next.rawValue)"
                modelOverride = next.cliFlags
            } else {
                // No fallback model available — try engine swap if the
                // user picked Codex (only direction we ever swap).
                if originalEngine == .codex {
                    engineOverride = .claude
                    modeOverride = ClaudeMode.askPermissions.cliFlags
                    modelOverride = ClaudeModel.opus47.cliFlags
                    effortOverride = []
                    rungFrom = "engine=codex"
                    rungTo = "engine=claude"
                } else {
                    // Claude with no fallback model and no engine swap
                    // available. Ladder ends here; tile stays failed.
                    return
                }
            }
        }

        // If after all rungs nothing changed, give up rather than
        // respawn an identical configuration.
        if modeOverride == (deadSession.modeFlagsOverride ?? [])
            && effortOverride == (deadSession.effortFlagsOverride ?? [])
            && modelOverride == (deadSession.modelFlagsOverride ?? [])
            && engineOverride == originalEngine {
            return
        }

        EventBus.shared.publish(
            .spawnFallbackApplied(
                sessionID: deadSession.id,
                title: deadSession.title,
                from: rungFrom,
                to: rungTo,
                reason: reason,
                projectName: projectName
            )
        )

        // Detach the dead session from the manager's session list and
        // IPC registry. The respawn produces a fresh TerminalSession
        // with a new UUID; the todo's `terminalSessionID` gets re-stamped
        // by spawnAndWire.
        ipcBroker?.unregisterSession(deadSession.id)
        sessions.removeAll { $0.id == deadSession.id }

        spawnAndWire(
            todo: todo,
            engine: engineOverride,
            cwd: cwd,
            agentName: agentName,
            projectName: projectName,
            teamName: teamName,
            teamID: teamID,
            teamAgents: teamAgents,
            modeFlagsOverride: modeOverride.isEmpty ? nil : modeOverride,
            modelFlagsOverride: modelOverride.isEmpty ? nil : modelOverride,
            effortFlagsOverride: effortOverride.isEmpty ? nil : effortOverride
        )
    }

    // MARK: - Picker reverse-lookup helpers

    /// Parse a `["--permission-mode", "<value>"]` array back into the
    /// original `ClaudeMode`. Returns nil when the array is empty
    /// (e.g. a session that didn't carry a mode override) or the
    /// value doesn't match any case — the ladder treats nil as "no
    /// fallback applies, skip this rung."
    private func parseClaudeMode(from flags: [String]) -> ClaudeMode? {
        guard let idx = flags.firstIndex(of: "--permission-mode"),
              idx + 1 < flags.count else { return nil }
        let value = flags[idx + 1]
        switch value {
        case "default":           return .askPermissions
        case "plan":              return .planMode
        case "auto":              return .autoMode
        case "bypassPermissions": return .bypassPermissions
        default:                  return nil
        }
    }

    private func parseCodexMode(from flags: [String]) -> CodexMode? {
        if flags.contains("danger-full-access") { return .fullAccess }
        if flags.isEmpty                         { return .defaultPermissions }
        return nil
    }

    private func parseClaudeModel(from flags: [String]) -> ClaudeModel? {
        guard let idx = flags.firstIndex(of: "--model"),
              idx + 1 < flags.count else { return nil }
        return ClaudeModel(rawValue: flags[idx + 1])
    }

    /// Codex's model flag is bundled as `-c model="<id>"`. Parse it
    /// back out of that shape.
    private func parseCodexModel(from flags: [String]) -> CodexModel? {
        for i in 0..<flags.count - 1 where flags[i] == "-c" {
            let payload = flags[i + 1]
            if let range = payload.range(of: "model=") {
                var raw = String(payload[range.upperBound...])
                raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return CodexModel(rawValue: raw)
            }
        }
        return nil
    }
}
