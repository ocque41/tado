import Foundation

@MainActor
enum RunInterventionWriter {
    struct Delivery: Equatable {
        let kind: String
        let runID: UUID
        let todoID: UUID?
        let sessionID: UUID?
        let path: String?
    }

    enum InterventionError: Error, Equatable {
        case emptyDirective
        case noDispatchTarget
        case noLiveSession(UUID)
    }

    static func writeEternal(run: EternalRun, directive: String) throws -> Delivery {
        let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InterventionError.emptyDirective }

        let inbox = EternalService.inboxDirURL(run)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "tado-use-\(stamp)-\(UUID().uuidString.prefix(8)).md"
        let url = inbox.appendingPathComponent(filename)
        try trimmed.write(to: url, atomically: true, encoding: .utf8)

        return Delivery(
            kind: "eternal_inbox",
            runID: run.id,
            todoID: nil,
            sessionID: nil,
            path: url.path
        )
    }

    static func sendDispatch(
        run: DispatchRun,
        directive: String,
        terminalManager: TerminalManager
    ) throws -> Delivery {
        let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InterventionError.emptyDirective }
        guard let targetTodoID = run.currentPhaseTodoID ?? run.architectTodoID else {
            throw InterventionError.noDispatchTarget
        }
        guard let session = terminalManager.session(forTodoID: targetTodoID) else {
            throw InterventionError.noLiveSession(targetTodoID)
        }

        let message = """
        Dispatch intervention for \(run.label):

        \(trimmed)
        """
        session.enqueueOrSend(message)

        return Delivery(
            kind: "dispatch_tile",
            runID: run.id,
            todoID: targetTodoID,
            sessionID: session.id,
            path: nil
        )
    }
}
