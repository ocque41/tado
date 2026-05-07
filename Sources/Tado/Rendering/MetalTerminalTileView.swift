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
    /// Tile-virtualization signal from the canvas. When false, the
    /// heavy Metal renderer branch is replaced with a lightweight
    /// placeholder so off-screen tiles don't pull GPU resources.
    /// Crucially, `spawnIfNeeded` still fires on `.onAppear` whether
    /// or not the tile is visible — decoupling the PTY lifecycle from
    /// view virtualization. Pre-fix, virtualization gated the entire
    /// `MetalTerminalTileView` mount in `StableTerminalContent`, so a
    /// freshly-spawned session whose tile happened to land outside
    /// the user's current viewport never ran `spawnIfNeeded`, the
    /// PTY never started, and the canvas showed an inert ghost.
    var isVisible: Bool = true
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
            if let core = session.coreSession, isVisible {
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
                        Palette.foreground
                            .opacity(0.35)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: flashActive)
            } else if session.coreSession != nil {
                // PTY is running but the tile is currently outside the
                // visible canvas viewport (virtualization). Render a
                // cheap placeholder rect so we don't pull GPU resources
                // for an off-screen MTKView. The session keeps running
                // in Rust; only the GPU mount is paused.
                offscreenPlaceholder
            } else {
                // No coreSession yet. Spawn is synchronous but can
                // fail; show pending until `.onAppear` runs, then swap
                // in the captured error so the user can see the real
                // cause (missing binary, bad cwd, env-related
                // posix_spawn failure, etc.) without having to run
                // from a terminal.
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

    /// Cheap rect shown for tiles that are currently outside the
    /// visible canvas viewport. Mirrors the look of the
    /// `OffscreenTilePlaceholder` from `TerminalTileView`. Inlined
    /// here so the PTY-bearing `MetalTerminalTileView` mount survives
    /// virtualization — `spawnIfNeeded` fires on the no-coreSession
    /// branch's `.onAppear` regardless of `isVisible`.
    private var offscreenPlaceholder: some View {
        Rectangle()
            .fill(Palette.canvas)
            .overlay(
                Image(systemName: "pause.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.foreground.opacity(0.15))
            )
    }

    // MARK: - Spawn wiring

    private func spawnIfNeeded() {
        guard session.coreSession == nil else { return }

        // Mark spawn-path entry on the system trace. Pairs with
        // `spawnIfNeeded.coreSessionSet` below — the gap between the
        // two is the user-visible "tado-core spawn pending…" lifetime.
        // See `Sources/Tado/Core/SpawnSignposts.swift` for usage.
        SpawnSignposts.event("spawnIfNeeded.entry")

        // === @MainActor capture-snapshot ============================
        //
        // Phase 1: capture every input the Task closure will need into
        // Sendable locals BEFORE we hop off-main. This is the entire
        // surface of state the spawn path touches; nothing below this
        // line should reach back into `self`, `session`, or any
        // SwiftUI binding.
        //
        // Pre-fix: the Dome context preamble (`prependedPrompt`) was
        // computed synchronously here on the main actor. When two or
        // more tiles `.onAppear`'d simultaneously (Eternal architect +
        // worker, panning to reveal a tile cluster), the FFI →
        // bt-core → SQLite scan serialised on the UI thread and the
        // canvas froze with "tado-core spawn pending…" stuck under a
        // loading wheel. The fix is to move ALL command/env building
        // off-main; the only @MainActor work that survives is the
        // tiny snapshot you see here and the post-spawn hop.
        // See `.claude/skills/tado-canvas-spawn-smooth/SKILL.md`.
        let isEternalWorker = session.isEternalWorker
        let projectRoot = session.projectRoot
        let eternalLoopKind = session.eternalLoopKind ?? "external"
        let eternalCodexPreFlags = session.eternalCodexPreFlags ?? []
        let eternalCodexPostFlags = session.eternalCodexPostFlags ?? []
        let eternalModelID = session.eternalModelID
        let eternalEffortLevel = session.eternalEffortLevel
        let eternalUseCodexExec = session.eternalUseCodexExec
        let eternalRunIDOpt = session.eternalRunID
        let eternalMode = session.eternalMode ?? "mega"
        let eternalDoneMarker = session.eternalDoneMarker ?? "ETERNAL-DONE"
        let eternalSkipPermissionsFlag = session.eternalSkipPermissionsFlag
        let eternalCodexPreFlagsForEnv = session.eternalCodexPreFlags
        let eternalCodexPostFlagsForEnv = session.eternalCodexPostFlags
        let eternalKind = session.eternalKind
        let preambleCtx = DomeContextPreamble.Context(
            agentName: agentName,
            projectName: session.projectName,
            projectID: session.projectID,
            projectRoot: session.projectRoot,
            teamName: session.teamName,
            teammates: session.teamAgents ?? [],
            scopeIsolation: session.scopeIsolation
        )
        let userPrompt = session.todoText
        let modeFlagsRaw = modeFlags
        let effortFlagsRaw = effortFlags
        let modelFlagsRaw = modelFlags
        let engineSnapshot = engine
        let agentNameSnapshot = agentName
        let ipcRootSnapshot = ipcRoot
        let claudeDisplaySnapshot = claudeDisplay
        let envProjectName = session.projectName
        let envProjectID = session.projectID
        let envProjectRoot = session.projectRoot
        let envTeamName = session.teamName
        let envTeamID = session.teamID
        let envAgentName = session.agentName
        let envTeamAgents = session.teamAgents
        let cols = gridCols(for: width)
        let rows = gridRows(for: height)
        let spawnedCwd = session.lastKnownCwd
        let theme = session.theme
        let sessionID = session.id
        let sessionTitle = session.title
        let sessionTodoText = session.todoText
        let projectName = session.projectName
        let palette = theme.ansiPalette
        let foregroundRGBA = theme.foregroundRGBA
        let backgroundRGBA = theme.backgroundRGBA

        // Pre-validate the eternal-worker invariant on the main actor:
        // a fatalError inside the detached Task surfaces in Console.app
        // but is much harder to debug than a synchronous crash here.
        if isEternalWorker, eternalRunIDOpt == nil {
            fatalError(
                "TerminalSession \(sessionID) has isEternalWorker=true but eternalRunID=nil — spawn path bug"
            )
        }

        Task {
            // === Off-main command + env build =======================
            //
            // From here on we run on a Task inheriting @MainActor only
            // for state writes; the heavy work (preamble fetch,
            // sanitizeFlags, command build, environment build) hops
            // through `Task.detached`/`await` boundaries so the UI
            // thread stays free. ProcessSpawner's `command`,
            // `environment`, `sanitizeFlags`, and `eternalWorkerEnv`
            // are pure functions — safe to call from any actor.

            // Resolve executable + args. Eternal workers don't get a
            // Dome preamble; only the agent branch does.
            let executable: String
            let args: [String]
            if isEternalWorker, let projectRoot {
                let cmd: (executable: String, args: [String])
                if eternalLoopKind == "internal" {
                    if engineSnapshot == .codex {
                        cmd = ProcessSpawner.internalCodexEternalCommand(
                            projectRoot: projectRoot,
                            codexPreFlags: eternalCodexPreFlags,
                            codexPostFlags: eternalCodexPostFlags
                        )
                    } else {
                        cmd = ProcessSpawner.internalEternalCommand(
                            projectRoot: projectRoot,
                            modelID: eternalModelID,
                            effortLevel: eternalEffortLevel
                        )
                    }
                } else {
                    cmd = ProcessSpawner.eternalWorkerCommand(projectRoot: projectRoot)
                }
                executable = cmd.executable
                args = cmd.args
            } else {
                // The async preamble fetch hops onto a background queue
                // for the FFI/SQLite hit. Returns byte-identical output
                // to the sync sibling; `spawn_pack_byte_equiv` pins the
                // contract.
                let enrichedPrompt = await SpawnSignposts.intervalAsync("preamble.fetch") {
                    await DomeContextPreamble.prependedPrompt(
                        for: preambleCtx,
                        userPrompt: userPrompt
                    )
                }
                let modeFlagsClean = ProcessSpawner.sanitizeFlags(modeFlagsRaw, engine: engineSnapshot)
                let effortFlagsClean = ProcessSpawner.sanitizeFlags(effortFlagsRaw, engine: engineSnapshot)
                let modelFlagsClean = ProcessSpawner.sanitizeFlags(modelFlagsRaw, engine: engineSnapshot)
                let cmd: (executable: String, args: [String])
                if engineSnapshot == .codex && eternalUseCodexExec {
                    let flags = modeFlagsClean + effortFlagsClean + modelFlagsClean
                    cmd = ProcessSpawner.codexExecCommand(for: enrichedPrompt, flags: flags)
                } else {
                    // Pass projectRoot + sessionID through so the .cowork
                    // branch of `command()` can build the
                    // `tado-cowork --folder … --run-id …` invocation.
                    // Other engines ignore both params.
                    cmd = ProcessSpawner.command(
                        for: enrichedPrompt,
                        engine: engineSnapshot,
                        modeFlags: modeFlagsClean,
                        effortFlags: effortFlagsClean,
                        modelFlags: modelFlagsClean,
                        agentName: agentNameSnapshot,
                        projectRoot: projectRoot,
                        runID: sessionID
                    )
                }
                executable = cmd.executable
                args = cmd.args
            }

            // Resolve env. ProcessSpawner.environment is pure; the
            // ipc-root branch is identical to the pre-fix code, just
            // off-main now.
            let envArray: [String]
            if let ipcRoot = ipcRootSnapshot {
                envArray = ProcessSpawner.environment(
                    sessionID: sessionID,
                    sessionName: sessionTodoText,
                    engine: engineSnapshot,
                    ipcRoot: ipcRoot,
                    projectName: envProjectName,
                    projectID: envProjectID,
                    projectRoot: envProjectRoot,
                    teamName: envTeamName,
                    teamID: envTeamID,
                    agentName: envAgentName,
                    teamAgents: envTeamAgents,
                    claudeDisplay: claudeDisplaySnapshot
                )
            } else {
                envArray = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            }
            var envDict: [String: String] = [:]
            envDict.reserveCapacity(envArray.count)
            for entry in envArray {
                if let eq = entry.firstIndex(of: "=") {
                    let key = String(entry[entry.startIndex..<eq])
                    let value = String(entry[entry.index(after: eq)...])
                    envDict[key] = value
                }
            }
            // Eternal-worker env merge — `eternalRunIDOpt` is guaranteed
            // non-nil by the @MainActor pre-check above.
            if isEternalWorker, let runID = eternalRunIDOpt {
                let eternalEnv = ProcessSpawner.eternalWorkerEnv(
                    runID: runID,
                    mode: eternalMode,
                    doneMarker: eternalDoneMarker,
                    modelID: eternalModelID,
                    effortLevel: eternalEffortLevel,
                    skipPermissions: eternalSkipPermissionsFlag,
                    codexPreFlags: eternalCodexPreFlagsForEnv,
                    codexPostFlags: eternalCodexPostFlagsForEnv,
                    perfMode: (eternalKind == "perf"),
                    sprintMode: (eternalKind == "sprint")
                )
                for (k, v) in eternalEnv { envDict[k] = v }
            }

            let spawnedCommand = executable
            let spawnedArgs = args
            let spawnedEnv = envDict

            // === Off-main Rust spawn ================================
            //
            // tado_last_spawn_error() reads a thread_local, so the
            // failure-reason capture MUST stay on the spawn thread —
            // hence the tuple return.
            let outcome: (TadoCore.Session?, String?) = await SpawnSignposts.intervalAsync("ptySpawn") {
                await Task.detached(priority: .userInitiated) {
                    let s = TadoCore.Session(
                        command: spawnedCommand,
                        args: spawnedArgs,
                        cwd: spawnedCwd,
                        environment: spawnedEnv,
                        cols: cols,
                        rows: rows
                    )
                    let reason = (s == nil)
                        ? (TadoCore.lastSpawnErrorFromCore()
                            ?? "tado_session_spawn returned null with no error detail")
                        : nil
                    return (s, reason)
                }.value
            }

            // Back on the main actor — `Task` from a SwiftUI view body
            // inherits the @MainActor isolation of the surrounding view.
            guard let spawned = outcome.0 else {
                let reason = outcome.1
                    ?? "tado_session_spawn returned null with no error detail"
                spawnError = reason
                NSLog("tado: TadoCore.Session spawn failed for \(sessionTodoText)")
                EventBus.shared.publish(
                    .terminalSpawnFailed(
                        sessionID: sessionID,
                        title: sessionTitle,
                        reason: reason,
                        projectName: projectName
                    )
                )
                return
            }
            spawned.setDefaultColors(fg: foregroundRGBA, bg: backgroundRGBA)
            if let palette {
                spawned.setAnsiPalette(palette)
            }
            session.coreSession = spawned
            session.processID = spawned.processID
            // The placeholder swap happens on the next SwiftUI body
            // evaluation triggered by `session.coreSession = spawned`.
            // This event marks the @MainActor-visible end of the
            // spawn pipeline; the duration from `spawnIfNeeded.entry`
            // is the user-perceived freeze window.
            SpawnSignposts.event("spawnIfNeeded.coreSessionSet")
            EventBus.shared.publish(
                .terminalSpawned(
                    sessionID: sessionID,
                    title: sessionTitle,
                    projectName: projectName
                )
            )
        }
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
