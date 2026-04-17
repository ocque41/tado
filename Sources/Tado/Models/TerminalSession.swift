import Foundation
import AppKit

enum SessionStatus: String, Equatable {
    case pending
    case running
    case needsInput
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
    var agentName: String?
    var teamName: String?
    var teamID: UUID?
    var projectRoot: String?
    var teamAgents: [String]?
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
        self.id = UUID()
        self.todoID = todoID
        self.todoText = todoText
        self.canvasPosition = canvasPosition
        self.gridIndex = gridIndex
        self.title = todoText
        self.lastActivityDate = Date()
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
        if status == .needsInput || status == .completed || status == .failed {
            sendToTerminal(text)
            markActivity()
        } else {
            promptQueue.append(text)
        }
    }

    /// Called by the activity timer — if idle and queue has items, send next
    func drainQueueIfReady() {
        guard status == .needsInput, !promptQueue.isEmpty else { return }
        let next = promptQueue.removeFirst()
        sendToTerminal(next)
        markActivity()
    }

    func markActivity() {
        lastActivityDate = Date()
        if status == .needsInput {
            status = .running
            onStatusChange?(.running)
        }
    }

    func checkIdle() {
        guard isRunning else { return }
        if Date().timeIntervalSince(lastActivityDate) > 5.0 {
            if status != .needsInput {
                status = .needsInput
                onStatusChange?(.needsInput)
            }
            drainQueueIfReady()
        } else {
            if status != .running {
                status = .running
                onStatusChange?(.running)
            }
        }
    }

    func markTerminated(exitCode: Int32?) {
        self.isRunning = false
        self.exitCode = exitCode
        if let code = exitCode, code == 0 {
            status = .completed
        } else {
            status = .failed
        }
        onStatusChange?(status)
    }
}
