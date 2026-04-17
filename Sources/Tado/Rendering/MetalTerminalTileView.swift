import SwiftUI
import AppKit

/// Phase 2.4 counterpart to `TerminalNSViewRepresentable` that renders via
/// `MetalTerminalView` + `TadoCore.Session` instead of SwiftTerm.
///
/// Mirrors the init signature so `StableTerminalContent` can branch on
/// `AppSettings.useMetalRenderer` without reshaping its callers. On first
/// body evaluation it lazily spawns a `TadoCore.Session` via
/// `ProcessSpawner.command` + `ProcessSpawner.environment` — the exact same
/// argv and env the SwiftTerm path would have used, so Claude/Codex CLIs
/// see an identical world.
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
    let width: CGFloat
    let height: CGFloat

    private var metrics: FontMetrics { FontMetrics.defaultMono(size: fontSize) }

    var body: some View {
        Group {
            if let core = session.coreSession {
                MetalTerminalView(
                    session: core,
                    cols: gridCols(for: width),
                    rows: gridRows(for: height),
                    metrics: metrics,
                    clearRGBA: session.theme.backgroundRGBA,
                    onDirty: { [weak session] in
                        // Runs on the main thread (MTKViewDelegate.draw
                        // callback); TerminalSession is @MainActor so this
                        // invocation is already isolated.
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
                    }
                )
            } else {
                // Spawn is synchronous but can fail; render a placeholder
                // that shows the error instead of silently crashing.
                Color.black.overlay(
                    Text("tado-core spawn pending…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
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
