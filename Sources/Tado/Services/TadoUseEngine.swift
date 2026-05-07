import Foundation
import SwiftData

/// Drives the Tado Use drawer's headless agent. One subprocess at a
/// time per turn; model / effort / permission mode are pulled from
/// the user's live `AppSettings` row at send time so that flipping
/// the global picker also flips the Use agent's behavior next turn.
///
/// Architecture (Claude path):
///   - `send(message:)` builds a per-turn MCP config JSON listing the
///     three servers the bridge needs: `tado` + `dome` (existing
///     stdio bridges) + `tado-use-bridge` (the in-process control-
///     socket proxy that exposes the six SwiftUI tools). Spawns
///     `claude -p <prompt> --output-format stream-json
///     --include-partial-messages --session-id <conversation-uuid>
///     --mcp-config <generated>.json`. The `--session-id` argument
///     is reused across every turn in the same conversation so
///     Claude resumes the prior session transparently — no separate
///     `--continue`/`--resume` plumbing required.
///   - The stdout pipe is read line-by-line on a background queue
///     and parsed as JSON-Lines. Parsed events are coalesced
///     (text deltas accumulate, ~50ms flush boundary) and a single
///     state-mutation hop to MainActor flushes them to the
///     `TadoUseState` streaming scratchpad. The active turn lives
///     in dedicated scratchpad scalars, NOT in `turns[]`, so per-
///     token mutations don't invalidate the array keypath that
///     `ForEach` reads.
///   - `stop()` SIGTERMs the active subprocess. The PTY child of the
///     CLI (and any MCP servers it spawned) inherits the same
///     process group and dies with it.
///
/// Codex path (deferred):
///   `codex exec` does not accept `--mcp-config` and emits a different
///   JSONL schema — its MCP integration lives in `~/.codex/config.toml`
///   only. For v1 the engine picker stays exposed (so a future
///   release can land Codex parity transparently) but selecting
///   Codex returns an explanatory turn instead of spawning. Canvas
///   tiles are unaffected; this constraint applies to Tado Use only.
@MainActor
final class TadoUseEngine {
    private weak var useState: TadoUseState?
    private weak var appState: AppState?
    private var settings: AppSettings?
    private var modelContext: ModelContext?
    private var process: Process?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var generatedMcpConfigPaths: [URL] = []
    /// Per-engine stable MCP config path. The config payload is a
    /// constant function of the engine (just MCP server entry points
    /// + binary paths), so we materialize it once and reuse on every
    /// turn instead of re-writing a UUID-named file per turn. That
    /// removes a JSON-serialize + atomic file write from the
    /// @MainActor path on every panel submission.
    private var cachedMcpConfigPath: [TerminalEngine: URL] = [:]

    /// Background actor that owns the JSONL parser + delta
    /// coalescer. Lives off MainActor so per-chunk JSON parses
    /// don't compete with SwiftUI's render budget. Built fresh per
    /// turn (cleaner lifecycle than persisting one across turns).
    private var streamProcessor: StreamProcessor?

    func bind(
        useState: TadoUseState,
        appState: AppState,
        settings: AppSettings?,
        modelContext: ModelContext
    ) {
        self.useState = useState
        self.appState = appState
        self.settings = settings
        self.modelContext = modelContext
    }

    /// Update the live `AppSettings` reference. Called by the panel
    /// whenever its `@Query` row updates so the engine always sees
    /// the freshest model / effort / permission picks.
    func updateSettings(_ s: AppSettings?) { self.settings = s }

    /// Send a user message. Appends the user turn, opens a
    /// streaming scratchpad for the assistant turn, and spawns the
    /// CLI. Idempotent during streaming — second calls are a no-op
    /// until `stop()` or natural completion.
    func send(_ rawMessage: String) {
        guard let useState else { return }
        guard !useState.isStreaming else { return }
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let engine = useState.engine
        let userTurn = TadoUseState.Turn(
            role: .user,
            text: trimmed,
            startedAt: Date(),
            finishedAt: Date(),
            engine: engine
        )
        useState.turns.append(userTurn)
        useState.beginStreamingTurn(engine: engine)
        useState.isStreaming = true
        useState.lastError = nil

        do {
            try spawn(engine: engine, prompt: trimmed)
        } catch {
            useState.lastError = "spawn_failed: \(error.localizedDescription)"
            useState.isStreaming = false
            useState.finalizeStreamingTurn()
        }
    }

    /// Hard-stop the active turn. Surfaces the partial assistant
    /// text already emitted and clears the streaming flag.
    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        // Process termination handler will fire and clean up; we
        // don't need to clear isStreaming here.
    }

    /// Called from the app's willTerminate hook so the subprocess
    /// dies with the parent.
    func teardown() {
        stop()
        cleanupGeneratedMcpConfigs()
    }

    /// Pre-spawn failure path: pin the active assistant turn with a
    /// terse explanation, clear streaming, surface the error in the
    /// footer chip. Used when an engine selection is unsupported in
    /// the current build (Codex without `--mcp-config`, etc.).
    private func failTurn(error code: String, message: String) {
        guard let useState else { return }
        useState.streamingText += message
        useState.lastError = code
        useState.isStreaming = false
        useState.finalizeStreamingTurn()
    }

    // MARK: - Spawn

    private func spawn(engine: TerminalEngine, prompt: String) throws {
        switch engine {
        case .codex:
            // Codex CLI does not currently accept `--mcp-config`,
            // and its MCP setup lives in `~/.codex/config.toml`
            // only. Surfaces an explanatory turn instead of
            // shelling out, so the user sees a clear next step
            // (switch to Claude in the header) rather than a
            // confusing CLI failure.
            failTurn(
                error: "codex_unsupported_v1",
                message: """
                Codex doesn't expose `--mcp-config` on the CLI yet, so the
                Tado Use bridge can't reach it from a per-turn spawn. \
                Use Claude in the header for now — Tado Use ships Codex \
                parity in a follow-up once `codex exec` learns the flag.
                """
            )
            return
        case .cowork:
            // Cowork doesn't expose a per-turn MCP config either — it
            // runs as a tab inside the Claude Desktop app and picks up
            // MCP servers from the user-installed `tado-cowork-plugin`
            // (the Tado-bundled plugin that ships the same 71-tool
            // surface as Tado Use's bridge). Tado Use streams a turn
            // by spawning `claude -p ... --mcp-config <ephemeral>`,
            // which has no Cowork analog. Surface an explanatory turn
            // pointing the operator at the Cowork tile flow + the
            // Bootstrap Cowork plugin button rather than failing in
            // a confusing way.
            failTurn(
                error: "cowork_unsupported_in_use_bridge",
                message: """
                Cowork doesn't accept a per-turn `--mcp-config`, so the \
                Tado Use bridge can't drive it from this panel. Two ways \
                forward: (1) submit a Cowork todo from the canvas — Tado \
                will fire `claude://cowork/new` and Cowork picks up the \
                bundled plugin's tools automatically; (2) for in-bridge \
                tool calling, switch the engine in the header to Claude. \
                If you haven't installed the plugin yet, click \
                "Bootstrap Cowork plugin" in Settings → Engine first.
                """
            )
            return
        case .claude:
            break
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let mcpConfigURL: URL
        if let cached = cachedMcpConfigPath[engine],
           FileManager.default.fileExists(atPath: cached.path) {
            mcpConfigURL = cached
        } else {
            mcpConfigURL = try writeMcpConfig(for: engine)
            cachedMcpConfigPath[engine] = mcpConfigURL
            generatedMcpConfigPaths.append(mcpConfigURL)
        }

        let composedPrompt = composedPrompt(prompt: prompt, engine: engine)
        let shellCommand = buildClaudeCommand(
            prompt: composedPrompt,
            mcpConfig: mcpConfigURL.path
        )
        proc.arguments = ["-l", "-c", shellCommand]

        // PATH inheritance: the user's Claude / Codex CLIs typically
        // live under ~/.claude/local/bin or /opt/homebrew/bin, both
        // of which `/bin/zsh -l` will load via the user's profile.
        // Don't whitelist a custom PATH here — let zsh do its job.
        var env = ProcessInfo.processInfo.environment
        // Tag downstream events so audit logs separate Use's drives
        // from human clicks. bt-core's actor classifier (see
        // Sources/CTadoCore/include/tado_core.h + the Rust side)
        // honors this for tools that bother to read it.
        env["TADO_ACTOR"] = "tado_use"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Fresh background processor for this turn. Owns the JSON
        // parse + delta accumulator; dispatches batched updates to
        // MainActor at ~50ms cadence so the SwiftUI render loop
        // never sees per-token chunks.
        let processor = StreamProcessor(engine: self)
        streamProcessor = processor

        // Background read source — parsing happens off MainActor.
        // The DispatchSource fires on the user-initiated queue;
        // we forward the chunk to the processor (no actor hop) and
        // let the processor decide when to flush to MainActor.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let outSource = DispatchSource.makeReadSource(
            fileDescriptor: outFD,
            queue: .global(qos: .userInitiated)
        )
        outSource.setEventHandler { [weak processor] in
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            processor?.feed(chunk)
        }
        outSource.resume()
        stdoutSource = outSource

        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let errSource = DispatchSource.makeReadSource(
            fileDescriptor: errFD,
            queue: .global(qos: .userInitiated)
        )
        errSource.setEventHandler { [weak processor] in
            let chunk = errPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            processor?.feedStderr(chunk)
        }
        errSource.resume()
        stderrSource = errSource

        proc.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleTermination(status: terminated.terminationStatus)
                }
            }
        }

        try proc.run()
        process = proc
    }

    // MARK: - Command builders

    private func buildClaudeCommand(prompt: String, mcpConfig: String) -> String {
        var parts: [String] = ["claude"]
        parts += ["-p", shellEscape(prompt)]
        parts += ["--output-format", "stream-json"]
        parts += ["--include-partial-messages"]
        parts += ["--verbose"]
        parts += ["--mcp-config", shellEscape(mcpConfig)]
        // Reuse the same conversation id on every turn; Claude
        // resumes the session transparently. `--session-id` takes a
        // UUID and works on first turn (creates) and every turn
        // after (resumes).
        if let convID = useState?.conversationID.uuidString {
            parts += ["--session-id", shellEscape(convID.lowercased())]
        }
        parts += claudePermissionFlags().map(shellEscape)
        if let model = settings?.claudeModel.rawValue, !model.isEmpty {
            parts += ["--model", shellEscape(model)]
        }
        if let effort = settings?.claudeEffort, effort != .auto {
            parts += ["--effort", shellEscape(effort.rawValue)]
        }
        return parts.joined(separator: " ")
    }

    /// Translate the user's existing Claude permission-mode pick into
    /// CLI flags. Mirror of `ClaudeMode.cliFlags`.
    private func claudePermissionFlags() -> [String] {
        let mode = settings?.claudeMode ?? .askPermissions
        return mode.cliFlags
    }

    /// Compose the prompt the CLI receives. First turn in a
    /// conversation gets the system preamble prepended; subsequent
    /// turns lean on `--session-id` resume to carry context. We
    /// detect "first turn" by counting non-system turns — at the
    /// time `composedPrompt` runs, the user turn for this message
    /// has already been appended, so a turn-count of 1 (just this
    /// user turn — the assistant lives in scratchpad now) means
    /// first turn.
    private func composedPrompt(prompt: String, engine: TerminalEngine) -> String {
        let turnCount = useState?.turns.count ?? 0
        if turnCount <= 1 {
            return systemPreamble() + "\n\n" + prompt
        }
        return prompt
    }

    private func systemPreamble() -> String {
        """
        You are running inside Tado Use — an autonomous control plane for Tado
        (a macOS app that turns todos into a canvas of Claude / Codex agent
        tiles, with Eternal/Dispatch run modes, a Dome knowledge vault, and a
        rich extension surface). You have THREE tool families:

        ### tado_* (12) — A2A / canvas tile primitives
        list, send, read, broadcast across running tiles. Query event log.
        Read/write Tado config + memory (the markdown notes Tado keeps under
        ~/Library/Application Support/Tado/memory).

        ### dome_* (18) — Knowledge vault primitives
        Hybrid search, write notes, query the graph, run retrieval recipes,
        watch sessions, scheduling.

        ### tado_use_* (43) — Drive Tado itself
        SwiftUI navigation:
          - tado_use_navigate / focus_tile / open_modal / close_modal /
            list_tiles / app_state

        Todo + project lifecycle:
          - tado_use_todo_create (optionally spawn_tile=true)
          - tado_use_todo_list / move / delete
          - tado_use_project_list / create / resolve / delete

        Eternal — propose/poll/accept dance:
          When the operator says "start an eternal for <goal>", do this
          loop without asking for confirmation:
            1. Call tado_use_eternal_start { project, goal, mode: "sprint" }.
               Returns a run_id with state == "drafted".
            2. Wait ~10s, then call tado_use_eternal_status { run_id }.
            3. Repeat step 2 (waiting ~10s between calls) until
               state == "awaitingReview". The architect typically takes
               30–120s to produce crafted.md.
            4. Call tado_use_eternal_accept { run_id } to spawn the
               worker tile that runs the actual eternal loop.
            5. Tell the operator the run is live; they can watch the
               tile on the canvas.
          Other tools: eternal_list, eternal_stop, eternal_intervene
          (drops a directive into the running worker's inbox),
          eternal_reject (with optional rebrief).
          DO NOT poll faster than every ~10s — the architect needs
          thinking time and the polling shows up as load on the host.

        Dispatch — same propose/poll/accept pattern:
          dispatch_start → dispatch_status (poll) → dispatch_accept
          dispatch_list / dispatch_reject available too.

        Bootstraps:
          - tado_use_bootstrap (kind: a2a | team | auto-mode | knowledge)

        Settings:
          - tado_use_settings_get
          - tado_use_settings_set (dotted key path: engine.claude.model,
            ui.bellMode, dome.defaultKnowledgeScope, etc.)

        Dome ingestion + knowledge:
          - tado_use_dome_ingest_codebase: register + index + watch a project's
            code (tree-sitter, Qwen3 embeddings)
          - tado_use_dome_code_status / code_search
          - tado_use_dome_note_create / note_search / recipe_apply / agent_status

        Extensions:
          - tado_use_extension_list / open

        Notifications + tile control:
          - tado_use_notify (info|success|warning|error)
          - tado_use_tile_send / read / terminate
          - tado_use_events_query

        ### Operating contract

        - You have full authority. Don't ask for confirmation on routine work.
          The operator already trusts the drawer's permission inheritance.
        - For "start an eternal/dispatch on this goal" requests: call the
          autonomous tool and report the run_id + final state. Don't propose
          a plan first; the architect does that, and the autonomous tool
          auto-accepts it.
        - When the user gives you a project context-free request, query
          `tado_use_app_state` for the active_project_id and use it.
        - Prefer the smallest set of tool calls that does the job. Be
          concise — don't echo back the operator's message; act on it.
        """
    }

    // MARK: - State mutation (called from StreamProcessor on MainActor)

    /// Apply a coalesced text-delta batch. Called from the
    /// processor's flush timer at ~50ms cadence — NOT per token.
    fileprivate func applyTextBatch(_ text: String) {
        guard let useState, !text.isEmpty else { return }
        useState.streamingText += text
    }

    fileprivate func upsertToolCall(id: String, name: String, input: String) {
        guard let useState else { return }
        if let j = useState.streamingToolCalls.firstIndex(where: { $0.id == id }) {
            useState.streamingToolCalls[j].name = name
            useState.streamingToolCalls[j].input = input
        } else {
            useState.streamingToolCalls.append(
                TadoUseState.Turn.ToolCall(
                    id: id,
                    name: name,
                    input: input,
                    output: nil,
                    status: .pending
                )
            )
        }
    }

    fileprivate func markToolCall(id: String, output: String, status: TadoUseState.Turn.ToolCall.Status) {
        guard let useState else { return }
        guard let j = useState.streamingToolCalls.firstIndex(where: { $0.id == id }) else { return }
        useState.streamingToolCalls[j].output = output
        useState.streamingToolCalls[j].status = status
    }

    fileprivate func recordUsage(input: Int?, output: Int?) {
        guard let useState else { return }
        if let input { useState.inputTokens += input }
        if let output { useState.outputTokens += output }
    }

    fileprivate func recordError(_ msg: String) {
        useState?.lastError = msg
    }

    /// Apply a captured snapshot from the StreamProcessor inline
    /// on @MainActor. Used by `handleTermination` so the final
    /// flush lands BEFORE `finalizeStreamingTurn()` zeroes the
    /// scratchpad (F-008).
    fileprivate func applyPendingBatch(_ batch: StreamProcessor.PendingBatch) {
        if !batch.text.isEmpty {
            applyTextBatch(batch.text)
        }
        for s in batch.toolStarts {
            upsertToolCall(id: s.id, name: s.name, input: s.input)
        }
        for r in batch.toolResults {
            markToolCall(id: r.id, output: r.body, status: r.status)
        }
        if batch.tokens.inputTokens != 0 || batch.tokens.outputTokens != 0 {
            recordUsage(input: batch.tokens.inputTokens, output: batch.tokens.outputTokens)
        }
        if let err = batch.error {
            recordError(err)
        }
    }

    // MARK: - Termination + cleanup

    private func handleTermination(status: Int32) {
        // Tear down the read sources first so no late chunks slip
        // through after we finalize.
        stdoutSource?.cancel(); stdoutSource = nil
        stderrSource?.cancel(); stderrSource = nil

        // Force a final flush of any pending coalesced text +
        // collect the stderr tail for error reporting. We're on
        // @MainActor here, so we apply the captured snapshot
        // inline instead of bouncing through DispatchQueue.main.async
        // (which wouldn't run until handleTermination returns —
        // F-008: trailing tokens were dropping into a scratchpad
        // that finalizeStreamingTurn had already cleared).
        if let processor = streamProcessor {
            if let pending = processor.drainPending() {
                applyPendingBatch(pending)
            }
            if status != 0 {
                let trailing = processor.stderrTail()
                let summary = trailing
                    .split(separator: "\n")
                    .last
                    .map(String.init) ?? "exit_code=\(status)"
                useState?.lastError = "engine_exited: \(summary)"
            }
        }
        streamProcessor = nil

        useState?.finalizeStreamingTurn()
        useState?.isStreaming = false
        process = nil

        // The MCP config file is engine-keyed and reused on every turn
        // (see `cachedMcpConfigPath` / `writeMcpConfig`). One file per
        // engine for the lifetime of the process; `teardown` →
        // `cleanupGeneratedMcpConfigs` removes them on app quit.
    }

    // MARK: - MCP config generation

    /// Write a per-turn MCP config file with the three servers the
    /// agent should see. Lives under
    /// `<storage-root>/tado-use/mcp-configs/` and is cleaned up on
    /// turn termination (per-turn) + app teardown (catch-all).
    private func writeMcpConfig(for engine: TerminalEngine) throws -> URL {
        let dir = StorePaths.root
            .appendingPathComponent("tado-use", isDirectory: true)
            .appendingPathComponent("mcp-configs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tadoMcpPath = resolveBinaryPath(name: "tado-mcp")
        let domeMcpPath = resolveBinaryPath(name: "dome-mcp")
        let bridgePath = resolveBinaryPath(name: "tado-use-bridge")

        // Both `claude --mcp-config` and `codex exec --mcp-config`
        // accept the same `{"mcpServers": {...}}` envelope. Each
        // server entry is `{"command":"...", "args":[...], "env":{...}}`.
        let payload: [String: Any] = [
            "mcpServers": [
                "tado": [
                    "command": tadoMcpPath,
                    "args": [],
                ],
                "dome": [
                    "command": domeMcpPath,
                    "args": [],
                ],
                "tado-use-bridge": [
                    "command": bridgePath,
                    "args": [],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        // Stable path keyed by engine — the payload is a constant
        // function of engine + binary paths, so we re-use the same
        // file on every turn. First-spawn pays one atomic write; every
        // subsequent turn pays nothing.
        let url = dir.appendingPathComponent("engine-\(engine.rawValue).json")
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func cleanupGeneratedMcpConfigs() {
        for url in generatedMcpConfigPaths {
            try? FileManager.default.removeItem(at: url)
        }
        generatedMcpConfigPaths.removeAll()
    }

    /// Resolve a Tado-bundled CLI binary path. Mirrors the lookup
    /// order used by `TadoMcpAutoRegister.resolveBinaryPath` and
    /// `DomeExtension.resolveBinaryPath`.
    private func resolveBinaryPath(name: String) -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        // Dev: tado-use-bridge is a Swift exec target, while
        // tado-mcp / dome-mcp are Rust binaries. Try Rust release
        // dir first (matches the Rust pair); fall back to Swift's
        // .build dir for the Swift target.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let rustReleaseBin = cwd
            .appendingPathComponent("tado-core/target/release")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: rustReleaseBin.path) {
            return rustReleaseBin.path
        }
        let swiftReleaseBin = cwd
            .appendingPathComponent(".build/release")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: swiftReleaseBin.path) {
            return swiftReleaseBin.path
        }
        let swiftDebugBin = cwd
            .appendingPathComponent(".build/debug")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: swiftDebugBin.path) {
            return swiftDebugBin.path
        }
        // Last resort: emit the bare name and let `zsh -l` PATH
        // search find it. If the binary isn't installed, the spawn
        // fails loudly which is exactly what we want.
        return name
    }

    // MARK: - Helpers

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - StreamProcessor (off-MainActor parser + coalescer)

/// Owns the JSONL line buffer + delta accumulator. Lives on a
/// dedicated dispatch queue so JSON parsing never competes with the
/// SwiftUI render budget. Flushes batched state updates to
/// `TadoUseEngine` on MainActor at a ~50 ms cadence.
///
/// **Why this isn't a Swift `actor`**: we want the dispatch source
/// callbacks to land on a known queue without an actor hop per
/// chunk; the queue is the synchronization primitive. State
/// touched by `feed` / `flushNow` is queue-confined; cross-thread
/// reads from MainActor go through `stderrTail()` which copies a
/// snapshot.
fileprivate final class StreamProcessor {
    /// Snapshot of pending state. Returned by `drainPending` so the
    /// caller (already on @MainActor at termination time) can apply
    /// it inline — without the previous `DispatchQueue.main.async`
    /// hop that wouldn't run until handleTermination returned.
    struct PendingBatch {
        let text: String
        let toolStarts: [(id: String, name: String, input: String)]
        let toolResults: [(id: String, body: String, status: TadoUseState.Turn.ToolCall.Status)]
        let tokens: (inputTokens: Int, outputTokens: Int)
        let error: String?
    }

    private weak var engine: TadoUseEngine?
    private let queue = DispatchQueue(label: "tado.use.stream-processor", qos: .userInitiated)
    private var stdoutBuffer = Data()
    private var _stderrBuffer = Data()
    private var pendingText = ""
    private var pendingToolStarts: [(id: String, name: String, input: String)] = []
    private var pendingToolResults: [(id: String, body: String, status: TadoUseState.Turn.ToolCall.Status)] = []
    private var pendingTokens: (inputTokens: Int, outputTokens: Int) = (0, 0)
    private var pendingError: String? = nil
    private var flushScheduled = false

    /// Coalesce text deltas for ~50 ms before flushing to the UI.
    /// Keeps SwiftUI re-renders to ~20 Hz max during streaming
    /// (down from the raw stream-json delta cadence which can
    /// burst above 60 Hz).
    private static let flushInterval: TimeInterval = 0.05

    init(engine: TadoUseEngine) {
        self.engine = engine
    }

    /// Called from the DispatchSource read handler on the queue's
    /// thread. Parses any complete lines, accumulates state,
    /// schedules a coalesced flush.
    func feed(_ chunk: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(chunk)
            while let nl = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stdoutBuffer.prefix(upTo: nl)
                self.stdoutBuffer.removeSubrange(0...nl)
                if lineData.isEmpty { continue }
                self.parseLine(Data(lineData))
            }
            self.scheduleFlushIfNeeded()
        }
    }

    func feedStderr(_ chunk: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self._stderrBuffer.append(chunk)
            // Cap to the last 64 KiB so a runaway log doesn't grow
            // unbounded.
            if self._stderrBuffer.count > 64 * 1024 {
                self._stderrBuffer.removeFirst(self._stderrBuffer.count - 64 * 1024)
            }
        }
    }

    /// Synchronously snapshot + clear all pending state under the
    /// queue's serial confinement. Called from `handleTermination`
    /// on @MainActor; the caller applies the batch inline (we
    /// can't enqueue a `DispatchQueue.main.async` from a
    /// MainActor-bound caller and expect it to run before that
    /// caller returns). Returns nil when nothing's pending.
    func drainPending() -> PendingBatch? {
        var batch: PendingBatch? = nil
        queue.sync { [weak self] in
            guard let self else { return }
            if self.pendingText.isEmpty &&
                self.pendingToolStarts.isEmpty &&
                self.pendingToolResults.isEmpty &&
                self.pendingTokens.inputTokens == 0 &&
                self.pendingTokens.outputTokens == 0 &&
                self.pendingError == nil {
                return
            }
            batch = PendingBatch(
                text: self.pendingText,
                toolStarts: self.pendingToolStarts,
                toolResults: self.pendingToolResults,
                tokens: self.pendingTokens,
                error: self.pendingError
            )
            self.pendingText = ""
            self.pendingToolStarts.removeAll()
            self.pendingToolResults.removeAll()
            self.pendingTokens = (0, 0)
            self.pendingError = nil
        }
        return batch
    }

    /// Snapshot of the stderr buffer for error reporting. Cheap
    /// enough to call from MainActor on termination.
    func stderrTail() -> String {
        var snapshot = Data()
        queue.sync { snapshot = self._stderrBuffer }
        return String(data: snapshot, encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    private func parseLine(_ lineData: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: lineData),
              let event = any as? [String: Any] else {
            return
        }
        let type = (event["type"] as? String) ?? ""

        switch type {
        case "system":
            // No-op for now — `--session-id` controls resume, not
            // the init event's `session_id`. Hooks, status updates,
            // etc. all hit this branch.
            break
        case "stream_event":
            if let inner = event["event"] as? [String: Any] {
                handleStreamEvent(inner)
            }
        case "user":
            // tool_result envelopes — close out matching tool calls.
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_result",
                       let id = block["tool_use_id"] as? String {
                        let body = (block["content"] as? String) ?? compactJSON(block["content"]) ?? ""
                        pendingToolResults.append((id: id, body: body, status: .complete))
                    }
                }
            }
        case "assistant":
            // Final message envelope after streaming completes —
            // pick up any tool_use blocks we didn't see streamed.
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        let input = compactJSON(block["input"]) ?? ""
                        pendingToolStarts.append((id: id, name: name, input: input))
                    }
                }
            }
        case "result":
            if let usage = event["usage"] as? [String: Any] {
                if let inT = usage["input_tokens"] as? Int {
                    pendingTokens.inputTokens += inT
                }
                if let outT = usage["output_tokens"] as? Int {
                    pendingTokens.outputTokens += outT
                }
            }
        case "error":
            if let msg = event["message"] as? String {
                pendingError = msg
            }
        default:
            break
        }
    }

    private func handleStreamEvent(_ event: [String: Any]) {
        let type = (event["type"] as? String) ?? ""
        switch type {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any],
               (block["type"] as? String) == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                let input = compactJSON(block["input"]) ?? ""
                pendingToolStarts.append((id: id, name: name, input: input))
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any] {
                let dtype = (delta["type"] as? String) ?? ""
                switch dtype {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        pendingText += text
                    }
                case "input_json_delta":
                    // Codex / Claude both accumulate the tool's
                    // `input` object as deltas. We don't have the
                    // tool id here, so just ignore — the final
                    // `assistant` envelope carries the assembled
                    // `input` block.
                    break
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func compactJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    // MARK: - Coalesced flush

    private func scheduleFlushIfNeeded() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flushScheduled = false
            self?.flushToMainActor()
        }
    }

    /// Capture the pending batch and forward to MainActor in ONE
    /// hop. Per text delta we'd hop ~50× per second; this caps
    /// the rate at ~20 Hz max during streaming.
    private func flushToMainActor() {
        // Snapshot + clear under the queue's serial confinement.
        let textBatch = pendingText
        let toolStarts = pendingToolStarts
        let toolResults = pendingToolResults
        let tokens = pendingTokens
        let errSnapshot = pendingError
        pendingText = ""
        pendingToolStarts.removeAll()
        pendingToolResults.removeAll()
        pendingTokens = (0, 0)
        pendingError = nil

        // Skip the hop entirely when there's nothing to flush.
        // Empty heartbeat flushes are common; don't bill them to
        // MainActor.
        if textBatch.isEmpty && toolStarts.isEmpty && toolResults.isEmpty
            && tokens.inputTokens == 0 && tokens.outputTokens == 0
            && errSnapshot == nil {
            return
        }

        let engineRef = self.engine
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let engine = engineRef else { return }
                if !textBatch.isEmpty {
                    engine.applyTextBatch(textBatch)
                }
                for s in toolStarts {
                    engine.upsertToolCall(id: s.id, name: s.name, input: s.input)
                }
                for r in toolResults {
                    engine.markToolCall(id: r.id, output: r.body, status: r.status)
                }
                if tokens.inputTokens != 0 || tokens.outputTokens != 0 {
                    engine.recordUsage(input: tokens.inputTokens, output: tokens.outputTokens)
                }
                if let errSnapshot {
                    engine.recordError(errSnapshot)
                }
            }
        }
    }
}
