import Foundation
import SwiftUI

@Observable
@MainActor
final class TerminalManager {
    var sessions: [TerminalSession] = []
    var ipcBroker: IPCBroker?

    func spawnSession(todoID: UUID, todoText: String, canvasPosition: CGPoint, gridIndex: Int, engine: TerminalEngine? = nil) -> TerminalSession {
        let session = TerminalSession(
            todoID: todoID,
            todoText: todoText,
            canvasPosition: canvasPosition,
            gridIndex: gridIndex,
            engine: engine
        )
        sessions.append(session)
        if let engine = engine {
            ipcBroker?.registerSession(session, engine: engine)
        }
        return session
    }

    func terminateSession(_ id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            session.terminalView?.send(txt: "\u{3}")
            session.isRunning = false
            ipcBroker?.unregisterSession(id)
        }
        sessions.removeAll { $0.id == id }
    }

    func terminateSessionForTodo(_ todoID: UUID) {
        if let session = sessions.first(where: { $0.todoID == todoID }) {
            session.terminalView?.send(txt: "\u{3}")
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

    func spawnAndWire(todo: TodoItem, engine: TerminalEngine) {
        let session = spawnSession(
            todoID: todo.id,
            todoText: todo.text,
            canvasPosition: todo.canvasPosition,
            gridIndex: todo.gridIndex,
            engine: engine
        )
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
    }
}
