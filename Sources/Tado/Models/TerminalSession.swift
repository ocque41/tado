import Foundation
import SwiftTerm
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
    var lastActivityDate: Date
    var status: SessionStatus = .running
    var promptQueue: [String] = []
    var unreadMessageCount: Int = 0
    var engine: TerminalEngine?
    var tileWidth: CGFloat = CanvasLayout.contentWidth
    var tileHeight: CGFloat = CanvasLayout.contentHeight
    weak var terminalView: LocalProcessTerminalView?

    var lastKnownCwd: String?
    var logBuffer: String = ""
    var projectName: String?
    var agentName: String?
    var onStatusChange: ((SessionStatus) -> Void)?
    var onCwdChange: ((String) -> Void)?
    var onLogFlush: ((String) -> Void)?

    func appendLog(_ text: String) {
        logBuffer.append(text)
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

    /// Send text to the terminal followed by Enter
    private func sendToTerminal(_ text: String) {
        guard let view = terminalView else { return }
        view.send(txt: text)
        // Send Enter as a separate write; use \r (CR) which matches the byte
        // that a real Enter keypress generates in the PTY (see EscapeSequences.cmdRet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            view.send(txt: "\r")
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
