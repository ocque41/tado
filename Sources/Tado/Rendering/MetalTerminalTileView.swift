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
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let core = session.coreSession {
                MetalTerminalView(
                    session: core,
                    cols: gridCols(for: width),
                    rows: gridRows(for: height),
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
        session.coreSession = spawned
    }

    // MARK: - Cell-size math

    /// Convert a pixel width to a terminal column count using the shared
    /// default monospace metrics. Phase 3 replaces this with a fully cached
    /// FontMetrics that follows the SwiftUI font size.
    private func gridCols(for width: CGFloat) -> UInt16 {
        let cellW = FontMetrics.defaultMono().cellWidth
        return UInt16(max(10, Int(width / cellW)))
    }

    private func gridRows(for height: CGFloat) -> UInt16 {
        let cellH = FontMetrics.defaultMono().cellHeight
        return UInt16(max(4, Int(height / cellH)))
    }
}
