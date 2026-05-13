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
                            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("tado-core spawn pending")
                                        .font(Typography.monoCaption)
                                        .foregroundStyle(Palette.textSecondary)
                                    Text(spawnPendingDetail(now: timeline.date))
                                        .font(Typography.monoMicro)
                                        .foregroundStyle(Palette.textTertiary)
                                        .lineLimit(3)
                                }
                            }
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

    private func spawnPendingDetail(now: Date) -> String {
        let phase = session.spawnPhase ?? "waiting for tile mount"
        if let started = session.spawnPhaseStartedAt {
            let elapsed = max(0, now.timeIntervalSince(started))
            return "\(phase) - \(String(format: "%.1fs", elapsed))"
        }
        return phase
    }

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

        let traceID = UUID()
        let diagnostics = SpawnDiagnosticsStore.shared
        session.spawnTraceID = traceID
        session.spawnLastError = nil
        session.spawnFirstOutputRecorded = false
        session.spawnPhase = "spawn.requested"
        session.spawnPhaseStartedAt = Date()
        diagnostics.startTrace(
            traceID: traceID,
            sessionID: sessionID,
            todoID: session.todoID,
            engine: engineSnapshot.rawValue,
            title: sessionTitle,
            projectName: projectName,
            projectRoot: envProjectRoot
        )
        EventBus.shared.publish(
            .terminalSpawnRequested(
                sessionID: sessionID,
                title: sessionTitle,
                engine: engineSnapshot.rawValue,
                projectName: projectName
            )
        )

        func beginPhase(_ phase: String, message: String? = nil) {
            let startedAt = Date()
            session.spawnPhase = phase
            session.spawnPhaseStartedAt = startedAt
            diagnostics.beginPhase(traceID: traceID, phase: phase, message: message)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard session.spawnTraceID == traceID,
                      session.spawnPhase == phase,
                      session.spawnPhaseStartedAt == startedAt else { return }
                EventBus.shared.publish(
                    .terminalSpawnPhaseSlow(
                        sessionID: sessionID,
                        title: sessionTitle,
                        phase: phase,
                        elapsedSeconds: Date().timeIntervalSince(startedAt),
                        projectName: projectName
                    )
                )
            }
        }

        func endPhase(
            _ phase: String,
            outcome: SpawnDiagnosticRecord.Outcome = .success,
            message: String? = nil,
            commandSummary: String? = nil
        ) {
            diagnostics.endPhase(
                traceID: traceID,
                phase: phase,
                outcome: outcome,
                message: message,
                commandSummary: commandSummary
            )
        }

        func failSpawn(phase: String, reason: String, preflight: Bool, commandSummary: String? = nil) {
            endPhase(phase, outcome: .failure, message: reason, commandSummary: commandSummary)
            diagnostics.finishTrace(
                traceID: traceID,
                outcome: .failure,
                message: reason,
                commandSummary: commandSummary
            )
            session.spawnPhase = "spawn.failed.\(phase)"
            session.spawnPhaseStartedAt = Date()
            session.spawnLastError = reason
            spawnError = "\(phase): \(reason)"
            NSLog("tado: TadoCore.Session spawn failed for \(sessionTodoText): \(phase): \(reason)")
            if preflight {
                EventBus.shared.publish(
                    .terminalSpawnPreflightFailed(
                        sessionID: sessionID,
                        title: sessionTitle,
                        phase: phase,
                        reason: reason,
                        projectName: projectName
                    )
                )
            }
            EventBus.shared.publish(
                .terminalSpawnFailed(
                    sessionID: sessionID,
                    title: sessionTitle,
                    reason: "\(phase): \(reason)",
                    projectName: projectName
                )
            )
        }

        Task {
            if isEternalWorker, eternalRunIDOpt == nil {
                let phase = "preflight.validate"
                beginPhase(phase)
                failSpawn(
                    phase: phase,
                    reason: "isEternalWorker=true but eternalRunID is nil",
                    preflight: true
                )
                return
            }

            // Resolve executable + args. Each heavy phase runs in a
            // detached task, then returns to the main actor only to update
            // visible phase state.
            let executable: String
            let args: [String]

            if isEternalWorker, let projectRoot {
                let phase = "command.build"
                beginPhase(phase, message: "eternal worker")
                let cmd = await Task.detached(priority: .userInitiated) {
                    if eternalLoopKind == "internal" {
                        if engineSnapshot == .codex {
                            return ProcessSpawner.internalCodexEternalCommand(
                                projectRoot: projectRoot,
                                codexPreFlags: eternalCodexPreFlags,
                                codexPostFlags: eternalCodexPostFlags
                            )
                        }
                        return ProcessSpawner.internalEternalCommand(
                            projectRoot: projectRoot,
                            modelID: eternalModelID,
                            effortLevel: eternalEffortLevel
                        )
                    }
                    return ProcessSpawner.eternalWorkerCommand(projectRoot: projectRoot)
                }.value
                executable = cmd.executable
                args = cmd.args
                endPhase(
                    phase,
                    commandSummary: SpawnDiagnosticsStore.commandSummary(
                        executable: executable,
                        args: args
                    )
                )
            } else {
                let preamblePhase = "preamble.fetch"
                beginPhase(preamblePhase)
                let enrichedPrompt = await SpawnSignposts.intervalAsync("preamble.fetch") {
                    await Self.preambleWithSoftDeadline(
                        ctx: preambleCtx,
                        userPrompt: userPrompt,
                        seconds: 2
                    )
                }
                let preambleMessage = enrichedPrompt == userPrompt
                    ? "preamble unavailable or missed soft deadline; raw prompt used"
                    : nil
                endPhase(preamblePhase, message: preambleMessage)

                if engineSnapshot != .cowork {
                    let capsPhase = "cliCapabilities.cache"
                    let status = CLICapabilities.shared.cacheStatus(for: engineSnapshot)
                    beginPhase(capsPhase, message: status.rawValue)
                    if status == .notStarted {
                        CLICapabilities.shared.prewarm(engineSnapshot)
                    }
                    let message: String
                    switch status {
                    case .ready:
                        message = CLICapabilities.shared.hasAnyValues(for: engineSnapshot)
                            ? "cache ready; engine flags filtered by CLI help data"
                            : "cache ready; no enum values found in CLI help"
                    case .probing:
                        message = "cache still probing; spawn proceeds without CLI help filtering"
                    case .notStarted:
                        message = "cache missing; background probe started and spawn proceeds unfiltered"
                    }
                    endPhase(capsPhase, message: message)
                }

                let commandPhase = "command.build"
                beginPhase(commandPhase)
                let cmd = await Task.detached(priority: .userInitiated) {
                    let modeFlagsClean = ProcessSpawner.sanitizeFlags(
                        modeFlagsRaw,
                        engine: engineSnapshot,
                        startProbeIfMissing: false
                    )
                    let effortFlagsClean = ProcessSpawner.sanitizeFlags(
                        effortFlagsRaw,
                        engine: engineSnapshot,
                        startProbeIfMissing: false
                    )
                    let modelFlagsClean = ProcessSpawner.sanitizeFlags(
                        modelFlagsRaw,
                        engine: engineSnapshot,
                        startProbeIfMissing: false
                    )
                    if engineSnapshot == .codex && eternalUseCodexExec {
                        let flags = modeFlagsClean + effortFlagsClean + modelFlagsClean
                        return ProcessSpawner.codexExecCommand(for: enrichedPrompt, flags: flags)
                    }
                    return ProcessSpawner.command(
                        for: enrichedPrompt,
                        engine: engineSnapshot,
                        modeFlags: modeFlagsClean,
                        effortFlags: effortFlagsClean,
                        modelFlags: modelFlagsClean,
                        agentName: agentNameSnapshot,
                        projectRoot: projectRoot,
                        runID: sessionID
                    )
                }.value
                executable = cmd.executable
                args = cmd.args
                endPhase(
                    commandPhase,
                    commandSummary: SpawnDiagnosticsStore.commandSummary(
                        executable: executable,
                        args: args
                    )
                )
            }

            let commandSummary = SpawnDiagnosticsStore.commandSummary(executable: executable, args: args)

            let envPhase = "environment.build"
            beginPhase(envPhase)
            let spawnedEnv = await Task.detached(priority: .userInitiated) {
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
                return envDict
            }.value
            endPhase(envPhase)

            let ptyPhase = "pty.spawn"
            beginPhase(ptyPhase, message: commandSummary)
            let outcome: (TadoCore.Session?, String?) = await SpawnSignposts.intervalAsync("ptySpawn") {
                await Task.detached(priority: .userInitiated) {
                    let s = TadoCore.Session(
                        command: executable,
                        args: args,
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

            guard let spawned = outcome.0 else {
                let reason = outcome.1
                    ?? "tado_session_spawn returned null with no error detail"
                failSpawn(
                    phase: ptyPhase,
                    reason: reason,
                    preflight: false,
                    commandSummary: commandSummary
                )
                return
            }
            endPhase(ptyPhase, commandSummary: commandSummary)

            let corePhase = "terminal.coreSessionSet"
            beginPhase(corePhase)
            spawned.setDefaultColors(fg: foregroundRGBA, bg: backgroundRGBA)
            if let palette {
                spawned.setAnsiPalette(palette)
            }
            session.coreSession = spawned
            session.processID = spawned.processID
            SpawnSignposts.event("spawnIfNeeded.coreSessionSet")
            endPhase(corePhase, commandSummary: commandSummary)
            session.spawnPhase = corePhase
            session.spawnPhaseStartedAt = Date()
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

    // MARK: - Preamble soft deadline

    /// Race the async preamble fetch against a deadline. On
    /// preamble-wins, returns the enriched prompt (preamble +
    /// separator + user prompt). On deadline-wins, returns the
    /// raw user prompt unchanged so the PTY launches immediately.
    ///
    /// Why this exists: the preamble fetch reaches into bt-core via
    /// FFI; bt-core opens a fresh rusqlite connection per call
    /// (per `tado-core/crates/bt-core/src/service.rs:1115`'s
    /// "per-RPC short-lived connection pattern"), and on cold launch
    /// the schema-init PRAGMAs dominate. An unbounded `await` here
    /// blocked the spawn pipeline indefinitely (caught live on
    /// 2026-05-08 via `sample(<pid>)` showing the spawn Task wedged
    /// inside `tado_dome_notes_list_scoped`'s rusqlite stack).
    ///
    /// This is NOT a watchdog on the dispatch chain — the preamble
    /// is enrichment, not the spawn itself. The contract with the
    /// agent is: preamble is best-effort, never blocking; the
    /// `spawn_pack_byte_equiv` test still pins the *content*
    /// equivalence between Swift and Rust composers when the
    /// preamble does fire.
    nonisolated private static func preambleWithSoftDeadline(
        ctx: DomeContextPreamble.Context,
        userPrompt: String,
        seconds: TimeInterval
    ) async -> String {
        let deadlineNanos = UInt64(max(0.1, seconds) * 1_000_000_000)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await DomeContextPreamble.prependedPrompt(
                    for: ctx,
                    userPrompt: userPrompt
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNanos)
                return nil
            }
            // First task to finish wins. `nil` from the timeout task
            // means the preamble didn't beat the deadline; fall
            // through to the raw user prompt.
            let winner = await group.next()
            group.cancelAll()
            switch winner {
            case .some(.some(let enriched)):
                return enriched
            case .some(.none), .none:
                return userPrompt
            }
        }
    }
}
