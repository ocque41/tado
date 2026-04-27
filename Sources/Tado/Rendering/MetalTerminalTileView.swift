import SwiftUI
import AppKit

/// Renders a single terminal tile using `MetalTerminalView` +
/// `TadoCore.Session`. On first body evaluation it lazily spawns the
/// PTY via `ProcessSpawner.command` + `ProcessSpawner.environment`, then
/// swaps in the Metal view as soon as `session.coreSession` is set.
struct MetalTerminalTileView: View {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let modeFlags: [String]
    let effortFlags: [String]
    let modelFlags: [String]
    let agentName: String?
    let claudeDisplay: ProcessSpawner.ClaudeDisplayEnv
    let fontSize: CGFloat
    let fontFamily: String
    let cursorBlink: Bool
    let bellMode: BellMode
    /// True when this is the keyboard-focused tile (`AppState.focusedTileTodoID`
    /// matches). `MetalTerminalView` uses this to keep `firstResponder` in
    /// sync with the accent ring — see the false→true transition in its
    /// `updateNSView`.
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat

    /// Toggled true briefly when the Metal view reports a visual bell;
    /// drives a semi-transparent white flash overlay that SwiftUI fades
    /// out. Kept in @State so the draw thread's callback doesn't fight
    /// with the view tree.
    @State private var flashActive: Bool = false

    /// Populated by `spawnIfNeeded` on a nil return so we can render the
    /// real error inside the tile instead of a generic "pending"
    /// placeholder. Mirrors `TadoCore.lastSpawnError` but scoped to this
    /// tile so subsequent successful spawns elsewhere don't overwrite
    /// what we're showing.
    @State private var spawnError: String?

    private var metrics: FontMetrics { FontMetrics.font(named: fontFamily, size: fontSize) }

    var body: some View {
        Group {
            if let core = session.coreSession {
                ZStack {
                    MetalTerminalView(
                        session: core,
                        cols: gridCols(for: width),
                        rows: gridRows(for: height),
                        metrics: metrics,
                        clearRGBA: session.theme.backgroundRGBA,
                        cursorBlink: cursorBlink,
                        bellMode: bellMode,
                        onDirty: { [weak session] in
                            // Runs on the main thread (MTKViewDelegate.draw
                            // callback); TerminalSession is @MainActor so
                            // this invocation is already isolated.
                            MainActor.assumeIsolated {
                                session?.markActivity()
                            }
                        },
                        onIdleTick: { [weak session] in
                            MainActor.assumeIsolated {
                                session?.checkIdle()
                            }
                        },
                        onTitleChange: { [weak session] title in
                            MainActor.assumeIsolated {
                                session?.title = title
                            }
                        },
                        onVisualBell: {
                            // Visual bell: full-tile white flash, fades
                            // over ~150 ms. Brief enough not to obscure
                            // output, bright enough to notice.
                            flashActive = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                flashActive = false
                            }
                        },
                        onBell: { [weak session] in
                            // Publish via the central bus so SoundPlayer
                            // (and future deliverers / the NDJSON log)
                            // see every bell — muted or not.
                            guard let session else { return }
                            EventBus.shared.publish(
                                .terminalBell(
                                    sessionID: session.id,
                                    title: session.title,
                                    projectName: session.projectName
                                )
                            )
                        },
                        onUserInput: { [weak session] in
                            // User typed a key into this PTY — start the
                            // idle-injection cooldown window so eternal
                            // workers don't type over a Ctrl+C dialog
                            // the user is trying to answer.
                            MainActor.assumeIsolated {
                                session?.noteUserInput()
                            }
                        },
                        isFocused: isFocused
                    )
                    if flashActive {
                        Color.white
                            .opacity(0.35)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: flashActive)
            } else {
                // Spawn is synchronous but can fail. Show pending until
                // .onAppear runs, then swap in the captured error so the
                // user can see the real cause (missing binary, bad cwd,
                // env-related posix_spawn failure, etc.) without having
                // to run from a terminal.
                Palette.canvas.overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        if let err = spawnError {
                            Text("tado-core spawn failed")
                                .font(Typography.monoCallout)
                                .foregroundStyle(Palette.danger)
                            Text(err)
                                .font(Typography.monoMicro)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(8)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        } else {
                            Text("tado-core spawn pending…")
                                .font(Typography.monoCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(8),
                    alignment: .topLeading
                )
                .onAppear {
                    spawnIfNeeded()
                }
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Spawn wiring

    private func spawnIfNeeded() {
        guard session.coreSession == nil else { return }

        // Eternal workers spawn one of two ways depending on
        // `session.eternalLoopKind`:
        //   - "external" (default): eternal-loop.sh wrapper respawns
        //     `claude -p` each turn; Stop-hook recursion counter resets
        //     every cycle.
        //   - "internal": `claude --permission-mode auto` interactive,
        //     no wrapper. One session for the whole run. Context grows
        //     and auto-compacts. Continuation driven by Tado's idle-
        //     injection (below) + a `/loop` command typed after the
        //     first turn.
        let executable: String
        let args: [String]
        if session.isEternalWorker, let projectRoot = session.projectRoot {
            let kind = session.eternalLoopKind ?? "external"
            let cmd: (executable: String, args: [String])
            if kind == "internal" {
                // session.eternalModelID / .eternalEffortLevel are stamped
                // from AppSettings at spawn time in EternalService.spawnWorker.
                // Without threading them here the TUI would read the user's
                // global ~/.claude/settings.json defaults and silently ignore
                // Tado's picker.
                cmd = ProcessSpawner.internalEternalCommand(
                    projectRoot: projectRoot,
                    modelID: session.eternalModelID,
                    effortLevel: session.eternalEffortLevel
                )
            } else {
                cmd = ProcessSpawner.eternalWorkerCommand(projectRoot: projectRoot)
            }
            executable = cmd.executable
            args = cmd.args
        } else {
            // C4: prepend a Dome-backed context preamble to every
            // non-Eternal agent spawn. The preamble carries identity,
            // project, team, and recent project notes so the agent
            // wakes with the facts it would otherwise have to derive
            // from env vars + tool calls. Silently passes through
            // unchanged if Dome is offline or the context is empty
            // (raw terminal with no project).
            // TerminalSession carries the project id from the TodoItem,
            // so Dome can inject recent project notes and a retrieval
            // contract before the agent sees the user's prompt.
            let preambleCtx = DomeContextPreamble.Context(
                agentName: agentName,
                projectName: session.projectName,
                projectID: session.projectID,
                projectRoot: session.projectRoot,
                teamName: session.teamName,
                teammates: session.teamAgents ?? []
            )
            let enrichedPrompt = DomeContextPreamble.prependedPrompt(
                for: preambleCtx,
                userPrompt: session.todoText
            )
            let cmd = ProcessSpawner.command(
                for: enrichedPrompt,
                engine: engine,
                modeFlags: modeFlags,
                effortFlags: effortFlags,
                modelFlags: modelFlags,
                agentName: agentName
            )
            executable = cmd.executable
            args = cmd.args
        }

        let envArray: [String]
        if let ipcRoot = ipcRoot {
            envArray = ProcessSpawner.environment(
                sessionID: session.id,
                sessionName: session.todoText,
                engine: engine,
                ipcRoot: ipcRoot,
                projectName: session.projectName,
                projectID: session.projectID,
                projectRoot: session.projectRoot,
                teamName: session.teamName,
                teamID: session.teamID,
                agentName: session.agentName,
                teamAgents: session.teamAgents,
                claudeDisplay: claudeDisplay
            )
        } else {
            envArray = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        }

        // ProcessSpawner.environment returns ["KEY=VALUE", …]. TadoCore takes
        // a dictionary; split on the first '=' (values may legitimately
        // contain '=' signs, e.g. PATH tokens with query strings).
        var envDict: [String: String] = [:]
        envDict.reserveCapacity(envArray.count)
        for entry in envArray {
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eq])
                let value = String(entry[entry.index(after: eq)...])
                envDict[key] = value
            }
        }

        // Merge eternal-worker env knobs (TADO_ETERNAL_MODE, TADO_MODEL,
        // TADO_ETERNAL_RUN_ID, etc.) after the base env so the wrapper
        // and any project hooks see them. External mode's eternal-loop.sh
        // reads these to build each `claude -p` invocation; internal
        // mode doesn't use a wrapper, but the run-id env var still makes
        // it through to any `.claude/` hooks the user has installed,
        // keeping them run-scoped in the same way.
        if session.isEternalWorker {
            // eternalRunID must be set for any isEternalWorker session — the
            // spawn-path in EternalService.spawnWorker stamps it before
            // spawnAndWire returns. A nil here means the spawn path forgot
            // to pass runID; hard-crash beats silently falling back to the
            // legacy per-project path (which no longer exists post-migration).
            guard let runID = session.eternalRunID else {
                fatalError(
                    "TerminalSession \(session.id) has isEternalWorker=true but eternalRunID=nil — spawn path bug"
                )
            }
            let eternalEnv = ProcessSpawner.eternalWorkerEnv(
                runID: runID,
                mode: session.eternalMode ?? "mega",
                doneMarker: session.eternalDoneMarker ?? "ETERNAL-DONE",
                modelID: session.eternalModelID,
                effortLevel: session.eternalEffortLevel,
                skipPermissions: session.eternalSkipPermissionsFlag
            )
            for (k, v) in eternalEnv { envDict[k] = v }
        }

        let cols = gridCols(for: width)
        let rows = gridRows(for: height)

        guard let spawned = TadoCore.Session(
            command: executable,
            args: args,
            cwd: session.lastKnownCwd,
            environment: envDict,
            cols: cols,
            rows: rows
        ) else {
            // TadoCore.Session.init? already logged + stashed the error.
            // Mirror it into @State so this tile's placeholder shows the
            // real cause instead of the generic pending text.
            let reason = TadoCore.lastSpawnError
                ?? "tado_session_spawn returned null with no error detail"
            spawnError = reason
            NSLog("tado: TadoCore.Session spawn failed for \(session.todoText)")
            EventBus.shared.publish(
                .terminalSpawnFailed(
                    sessionID: session.id,
                    title: session.title,
                    reason: reason,
                    projectName: session.projectName
                )
            )
            return
        }
        // Apply the tile's theme so blank / erased regions use the tile
        // background and SGR reset picks up the tile foreground. Must
        // happen before the first frame — `MetalTerminalView` reads
        // `session.theme` on its own to set the MTKView clear color.
        let theme = session.theme
        spawned.setDefaultColors(fg: theme.foregroundRGBA, bg: theme.backgroundRGBA)
        // Opt-in ANSI palette: themes that carry one (Solarized, Dracula,
        // Monokai, Nord, Tokyo Night) push their own 16 colors so the
        // agent's SGR reds/greens match the theme. Themes without a
        // palette keep the gruvbox-flavored default baked into tado-core.
        if let palette = theme.ansiPalette {
            spawned.setAnsiPalette(palette)
        }
        session.coreSession = spawned
        EventBus.shared.publish(
            .terminalSpawned(
                sessionID: session.id,
                title: session.title,
                projectName: session.projectName
            )
        )
    }

    // MARK: - Cell-size math

    /// Convert a pixel width to a terminal column count using the size
    /// resolved from AppSettings. Tiles with a small font get more cols.
    private func gridCols(for width: CGFloat) -> UInt16 {
        UInt16(max(10, Int(width / metrics.cellWidth)))
    }

    private func gridRows(for height: CGFloat) -> UInt16 {
        UInt16(max(4, Int(height / metrics.cellHeight)))
    }
}
