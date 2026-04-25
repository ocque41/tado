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

    /// Agent has finished a turn and is sitting at its idle prompt.
    /// Lower-urgency than `.terminalAwaitingResponse` — the user does
    /// NOT need to take a specific action; the next instruction can
    /// wait. Routed quietly (dock badge only by default) so a session
    /// that idles 20 times across the day doesn't fill the screen.
    static func terminalIdle(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.idle",
            severity: .info,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Idle: \(title)",
            body: ""
        )
    }

    /// Agent is actively asking a question, presenting a plan, or
    /// awaiting numbered selection — detected by scraping the grid
    /// for selector arrows / `(y/n)` / plan-approval phrasing. Higher
    /// urgency: routed to inApp + system + sound by default so the
    /// user notices even when Tado isn't frontmost.
    static func terminalAwaitingResponse(sessionID: UUID, title: String, projectName: String?) -> TadoEvent {
        TadoEvent(
            type: "terminal.awaitingResponse",
            severity: .warning,
            source: Source(kind: "terminal", sessionID: sessionID, projectName: projectName),
            title: "Needs response: \(title)",
            body: "Agent is asking a question or awaiting plan approval."
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

    // MARK: - Dome (second-brain daemon) lifecycle

    /// Emitted after `tado_dome_start` returns success — the Unix
    /// socket is bound and bt-core's RPC loop is accepting connections.
    /// Used by the Calendar surface to render a daemon-up marker on
    /// the activity timeline, and by any agent-facing CLI that wants
    /// to confirm Dome is actually reachable before hitting the socket.
    ///
    /// The body includes the manual `claude mcp add dome` command as
    /// a fallback until Phase 3b lands full MCP auto-registration.
    /// Users can copy/paste from the Notifications extension to hook
    /// dome-mcp into their Claude Code scope.
    static func domeDaemonStarted(vaultPath: String, mcpBinaryPath: String) -> TadoEvent {
        let registerHint = "claude mcp add dome --scope user -- \(mcpBinaryPath) \(vaultPath) <agent-token>"
        return TadoEvent(
            type: "dome.daemonStarted",
            severity: .success,
            source: .system,
            title: "Dome second-brain online",
            body: "Vault at \(vaultPath)\n\nRegister MCP (first run only):\n\(registerHint)"
        )
    }

    /// Emitted when `tado_dome_start` returns a non-zero status. The
    /// code surfaces in the body so we can diagnose in the Notifications
    /// extension without tailing a separate log file. Severity is
    /// `.error` because failure here means every agent in every
    /// terminal loses `dome_search` / `dome_read` / `dome_note` for
    /// the session.
    static func domeDaemonFailed(code: Int32, vaultPath: String) -> TadoEvent {
        TadoEvent(
            type: "dome.daemonFailed",
            severity: .error,
            source: .system,
            title: "Dome daemon failed to start",
            body: "tado_dome_start returned \(code) for vault \(vaultPath)"
        )
    }

    /// Progress marker for the first-launch bge-small-en-v1.5 model
    /// download. Phase-4 plumbing — factory added here so the Calendar
    /// surface can subscribe without requiring a second TadoEvent.swift
    /// edit later. `progress` is 0.0–1.0.
    static func domeModelDownloading(progress: Double) -> TadoEvent {
        TadoEvent(
            type: "dome.modelDownloading",
            severity: .info,
            source: .system,
            title: "Dome embedding model",
            body: String(format: "Downloading bge-small-en-v1.5 — %.0f%%", progress * 100)
        )
    }
}
