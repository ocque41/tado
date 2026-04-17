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
                        }
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
                Color.black.overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        if let err = spawnError {
                            Text("tado-core spawn failed")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        } else {
                            Text("tado-core spawn pending…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
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

        let (executable, args) = ProcessSpawner.command(
            for: session.todoText,
            engine: engine,
            modeFlags: modeFlags,
            effortFlags: effortFlags,
            modelFlags: modelFlags,
            agentName: agentName
        )

        let envArray: [String]
        if let ipcRoot = ipcRoot {
            envArray = ProcessSpawner.environment(
                sessionID: session.id,
                sessionName: session.todoText,
                engine: engine,
                ipcRoot: ipcRoot,
                projectName: session.projectName,
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
            spawnError = TadoCore.lastSpawnError
                ?? "tado_session_spawn returned null with no error detail"
            NSLog("tado: TadoCore.Session spawn failed for \(session.todoText)")
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
