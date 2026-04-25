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
}
