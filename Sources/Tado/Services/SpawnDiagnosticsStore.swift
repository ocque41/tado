import Foundation

struct SpawnDiagnosticRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case traceStarted
        case phaseStarted
        case phaseEnded
        case traceFinished
    }

    enum Outcome: String, Codable {
        case started
        case success
        case failure
        case skipped
    }

    var traceID: UUID
    var sessionID: UUID
    var todoID: UUID
    var engine: String
    var title: String
    var projectName: String?
    var projectRoot: String?
    var kind: Kind
    var phase: String?
    var outcome: Outcome
    var message: String?
    var commandSummary: String?
    var durationMs: Double?
    var timestamp: Date
}

struct SpawnTracePhase: Codable, Equatable {
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Double?
    var outcome: SpawnDiagnosticRecord.Outcome
    var message: String?
}

struct SpawnTraceSummary: Codable, Equatable {
    var traceID: UUID
    var sessionID: UUID
    var todoID: UUID
    var engine: String
    var title: String
    var projectName: String?
    var projectRoot: String?
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Double?
    var outcome: SpawnDiagnosticRecord.Outcome
    var currentPhase: String?
    var error: String?
    var commandSummary: String?
    var phases: [SpawnTracePhase]
}

/// Durable per-spawn traces for the tile startup path.
///
/// This sits beside `SpawnSignposts`: signposts are for Instruments,
/// while this store is for the user-visible answer to "what phase
/// stalled or failed?" Records are appended on a background queue to
/// avoid adding disk IO to the spawn path.
final class SpawnDiagnosticsStore {
    static let shared = SpawnDiagnosticsStore()

    private struct RunningTrace {
        var summary: SpawnTraceSummary
        var currentPhaseStartedAt: Date?
    }

    private let queue = DispatchQueue(label: "com.tado.spawn.diagnostics", qos: .utility)
    private let logURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private var traces: [UUID: RunningTrace] = [:]
    private var recentSummaries: [SpawnTraceSummary] = []
    private let recentLimit = 80

    init(logURL: URL = StorePaths.logsDir.appendingPathComponent("spawn-traces.ndjson")) {
        self.logURL = logURL
    }

    @discardableResult
    func startTrace(
        traceID: UUID = UUID(),
        sessionID: UUID,
        todoID: UUID,
        engine: String,
        title: String,
        projectName: String?,
        projectRoot: String?
    ) -> UUID {
        queue.async {
            let now = Date()
            let summary = SpawnTraceSummary(
                traceID: traceID,
                sessionID: sessionID,
                todoID: todoID,
                engine: engine,
                title: title,
                projectName: projectName,
                projectRoot: projectRoot,
                startedAt: now,
                endedAt: nil,
                durationMs: nil,
                outcome: .started,
                currentPhase: nil,
                error: nil,
                commandSummary: nil,
                phases: []
            )
            self.traces[traceID] = RunningTrace(summary: summary, currentPhaseStartedAt: nil)
            self.append(SpawnDiagnosticRecord(
                traceID: traceID,
                sessionID: sessionID,
                todoID: todoID,
                engine: engine,
                title: title,
                projectName: projectName,
                projectRoot: projectRoot,
                kind: .traceStarted,
                phase: nil,
                outcome: .started,
                message: nil,
                commandSummary: nil,
                durationMs: nil,
                timestamp: now
            ))
        }
        return traceID
    }

    func beginPhase(traceID: UUID, phase: String, message: String? = nil) {
        queue.async {
            guard var running = self.traces[traceID] else { return }
            let now = Date()
            running.summary.currentPhase = phase
            running.currentPhaseStartedAt = now
            running.summary.phases.append(SpawnTracePhase(
                name: phase,
                startedAt: now,
                endedAt: nil,
                durationMs: nil,
                outcome: .started,
                message: message
            ))
            self.traces[traceID] = running
            self.appendRecord(
                running.summary,
                kind: .phaseStarted,
                phase: phase,
                outcome: .started,
                message: message,
                durationMs: nil,
                timestamp: now
            )
        }
    }

    func endPhase(
        traceID: UUID,
        phase: String,
        outcome: SpawnDiagnosticRecord.Outcome = .success,
        message: String? = nil,
        commandSummary: String? = nil
    ) {
        queue.async {
            guard var running = self.traces[traceID] else { return }
            let now = Date()
            let started = running.currentPhaseStartedAt ?? now
            let durationMs = now.timeIntervalSince(started) * 1000
            if let idx = running.summary.phases.lastIndex(where: { $0.name == phase && $0.endedAt == nil }) {
                running.summary.phases[idx].endedAt = now
                running.summary.phases[idx].durationMs = durationMs
                running.summary.phases[idx].outcome = outcome
                running.summary.phases[idx].message = message
            }
            if running.summary.currentPhase == phase {
                running.summary.currentPhase = nil
                running.currentPhaseStartedAt = nil
            }
            if let commandSummary {
                running.summary.commandSummary = commandSummary
            }
            if outcome == .failure {
                running.summary.error = message
            }
            self.traces[traceID] = running
            self.appendRecord(
                running.summary,
                kind: .phaseEnded,
                phase: phase,
                outcome: outcome,
                message: message,
                commandSummary: commandSummary,
                durationMs: durationMs,
                timestamp: now
            )
        }
    }

    func finishTrace(
        traceID: UUID,
        outcome: SpawnDiagnosticRecord.Outcome,
        message: String? = nil,
        commandSummary: String? = nil
    ) {
        queue.async {
            guard var running = self.traces.removeValue(forKey: traceID) else { return }
            let now = Date()
            running.summary.endedAt = now
            running.summary.durationMs = now.timeIntervalSince(running.summary.startedAt) * 1000
            running.summary.outcome = outcome
            if let message {
                running.summary.error = message
            }
            if let commandSummary {
                running.summary.commandSummary = commandSummary
            }
            running.summary.currentPhase = nil
            self.recentSummaries.insert(running.summary, at: 0)
            if self.recentSummaries.count > self.recentLimit {
                self.recentSummaries.removeLast(self.recentSummaries.count - self.recentLimit)
            }
            self.appendRecord(
                running.summary,
                kind: .traceFinished,
                phase: nil,
                outcome: outcome,
                message: message,
                commandSummary: commandSummary,
                durationMs: running.summary.durationMs,
                timestamp: now
            )
        }
    }

    func recentSummariesSnapshotForTests() -> [SpawnTraceSummary] {
        queue.sync { recentSummaries }
    }

    func drainForTests() {
        queue.sync {}
    }

    static func commandSummary(executable: String, args: [String]) -> String {
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if executable == "/bin/zsh",
           args.count >= 3,
           args[1] == "-c" {
            let shellCommand = args[2]
            let commandName = shellCommand
                .split(separator: " ", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? "shell"
            return "\(executableName) -l -c <\(commandName) command redacted>"
        }

        let safeArgs = args.prefix(6).map { arg -> String in
            if arg.contains("\n") { return "<multiline redacted>" }
            if arg.count > 64 { return "<\(arg.count) chars redacted>" }
            return arg
        }
        let suffix = args.count > safeArgs.count ? " …" : ""
        return ([executableName] + safeArgs).joined(separator: " ") + suffix
    }

    private func appendRecord(
        _ summary: SpawnTraceSummary,
        kind: SpawnDiagnosticRecord.Kind,
        phase: String?,
        outcome: SpawnDiagnosticRecord.Outcome,
        message: String?,
        commandSummary: String? = nil,
        durationMs: Double?,
        timestamp: Date
    ) {
        append(SpawnDiagnosticRecord(
            traceID: summary.traceID,
            sessionID: summary.sessionID,
            todoID: summary.todoID,
            engine: summary.engine,
            title: summary.title,
            projectName: summary.projectName,
            projectRoot: summary.projectRoot,
            kind: kind,
            phase: phase,
            outcome: outcome,
            message: message,
            commandSummary: commandSummary,
            durationMs: durationMs,
            timestamp: timestamp
        ))
    }

    private func append(_ record: SpawnDiagnosticRecord) {
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return }
        try? AtomicStore.appendLine(line, to: logURL)
    }
}
