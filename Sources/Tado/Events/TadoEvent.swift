import Foundation

/// A durable, typed event emitted somewhere in Tado (terminal
/// lifecycle, IPC arrival, Eternal phase transition, user broadcast,
/// etc.). Every event carries enough context to be surfaced in a
/// system notification, stored in the NDJSON event log, queried from
/// the CLI/MCP, and deep-linked back to its source view.
///
/// The `type` field is a dotted string ("terminal.completed",
/// "eternal.phaseCompleted") rather than a Swift enum so new event
/// types can be added without breaking persistence or requiring a
/// migration. Convenience factories at the bottom of this file
/// construct well-formed events with the right `type`/`severity`.
struct TadoEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let ts: Date
    let type: String
    let severity: Severity
    let source: Source
    let title: String
    let body: String
    var actions: [Action]
    var read: Bool

    enum Severity: String, Codable, CaseIterable {
        case info
        case success
        case warning
        case error
    }

    /// Where the event originated — enough identity to deep-link back
    /// to the relevant tile / run / project. All fields optional so a
    /// purely system-wide event (`system.appLaunched`) can leave them
    /// all nil.
    struct Source: Codable, Equatable {
        var kind: String = ""
        var sessionID: UUID? = nil
        var projectID: UUID? = nil
        var projectName: String? = nil
        var runID: UUID? = nil

        static let system = Source(kind: "system")
    }

    /// A user-actionable button surfaced on the notification or
    /// in-app banner. `deepLink` is a `tado://` URL the app resolves
    /// via `TadoApp`'s URL handler (registered in Packet 5).
    struct Action: Codable, Equatable {
        var label: String
        var deepLink: String
    }

    init(
        id: UUID = UUID(),
        ts: Date = Date(),
        type: String,
        severity: Severity = .info,
        source: Source = Source(),
        title: String,
        body: String = "",
        actions: [Action] = [],
        read: Bool = false
    ) {
        self.id = id
        self.ts = ts
        self.type = type
        self.severity = severity
        self.source = source
        self.title = title
        self.body = body
        self.actions = actions
        self.read = read
    }
}

// MARK: - Factories

/// Typed factories so call sites stay concise and can't typo an event
/// `type` string. Group per subsystem; keep signatures boring.
extension TadoEvent {
    static func terminalSpawned(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.spawned",
            severity: .info,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: title,
            body: "Terminal started."
        )
    }

    static func terminalSpawnFailed(sessionID: UUID?, title: String, reason: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.spawnFailed",
            severity: .error,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Spawn failed: \(title)",
            body: reason
        )
    }

    static func terminalNeedsInput(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.needsInput",
            severity: .info,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Waiting for input: \(title)",
            body: "Terminal is idle; queued prompts (if any) will drain."
        )
    }

    static func terminalCompleted(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.completed",
            severity: .success,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Completed: \(title)",
            body: "Terminal exited successfully."
        )
    }

    static func terminalFailed(sessionID: UUID, title: String, exitCode: Int32?, projectName: String?) -> TadoEvent {
        let codeStr = exitCode.map { String($0) } ?? "abnormal"
        return TadoEvent(
            type: "terminal.failed",
            severity: .error,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Failed: \(title)",
            body: "Exit code: \(codeStr)"
        )
    }

    static func terminalBell(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.bell",
            severity: .info,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Bell: \(title)",
            body: ""
        )
    }

    static func ipcMessageReceived(sessionID: UUID, title: String, snippet: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "ipc.messageReceived",
            severity: .info,
            source: Source(kind: "ipc", sessionID: sessionID, projectName: projectName),
            title: "Message for \(title)",
            body: snippet
        )
    }

    static func systemAppLaunched() -> TadoEvent {
        TadoEvent(type: "system.appLaunched", severity: .info, source: .system, title: "Tado launched")
    }

    static func systemMigrationRan(id: Int, name: String) -> TadoEvent {
        TadoEvent(
            type: "system.migrationRan",
            severity: .info,
            source: .system,
            title: "Migration \(id) applied",
            body: name
        )
    }

    static func userBroadcast(title: String, body: String, severity: Severity = .info) -> TadoEvent {
        TadoEvent(type: "user.broadcast", severity: severity, source: .system, title: title, body: body)
    }
}
