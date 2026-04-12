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
    weak var terminalView: LocalProcessTerminalView?

    var lastKnownCwd: String?
    var logBuffer: String = ""
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

    /// Send immediately if agent is idle, otherwise queue
    func enqueueOrSend(_ text: String) {
        if status == .needsInput || status == .completed || status == .failed {
            terminalView?.send(txt: text + "\r")
            markActivity()
        } else {
            promptQueue.append(text)
        }
    }

    /// Called by the activity timer — if idle and queue has items, send next
    func drainQueueIfReady() {
        guard status == .needsInput, !promptQueue.isEmpty else { return }
        let next = promptQueue.removeFirst()
        terminalView?.send(txt: next + "\r")
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
