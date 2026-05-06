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
///   - The stdout pipe is read line-by-line and parsed as JSON-Lines.
///     Assistant text deltas accumulate into the active turn;
///     `tool_use` blocks open ToolCall entries; `tool_result` blocks
///     close them; `result` updates token usage and finishes the turn.
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
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var generatedMcpConfigPaths: [URL] = []

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

    /// Send a user message. Appends a user turn, spawns the CLI,
    /// streams the response into a fresh assistant turn. Idempotent
    /// during streaming — second calls are a no-op until `stop()`
    /// or natural completion.
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

        let assistantTurn = TadoUseState.Turn(
            role: .assistant,
            text: "",
            startedAt: Date(),
            engine: engine
        )
        useState.turns.append(assistantTurn)
        useState.isStreaming = true
        useState.lastError = nil

        do {
            try spawn(engine: engine, prompt: trimmed)
        } catch {
            useState.lastError = "spawn_failed: \(error.localizedDescription)"
            useState.isStreaming = false
            finishLastAssistantTurn()
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
        appendAssistantText(message)
        useState.lastError = code
        useState.isStreaming = false
        finishLastAssistantTurn()
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
        case .claude:
            break
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let mcpConfigURL = try writeMcpConfig(for: engine)
        generatedMcpConfigPaths.append(mcpConfigURL)

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

        // Stream stdout line-by-line into the parser. Using
        // DispatchSource instead of Pipe.readabilityHandler so the
        // file descriptor cleanup is explicit.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let outSource = DispatchSource.makeReadSource(
            fileDescriptor: outFD,
            queue: .global(qos: .userInitiated)
        )
        outSource.setEventHandler { [weak self] in
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.consumeStdout(chunk)
                }
            }
        }
        outSource.resume()
        stdoutSource = outSource

        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let errSource = DispatchSource.makeReadSource(
            fileDescriptor: errFD,
            queue: .global(qos: .userInitiated)
        )
        errSource.setEventHandler { [weak self] in
            let chunk = errPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.consumeStderr(chunk)
                }
            }
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
    /// has already been appended, so a turn-count of 2 (this user
    /// turn + the active assistant placeholder) means first turn.
    private func composedPrompt(prompt: String, engine: TerminalEngine) -> String {
        let turnCount = useState?.turns.count ?? 0
        if turnCount <= 2 {
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

        ### tado_use_* (~36) — Drive Tado itself
        SwiftUI navigation:
          - tado_use_navigate / focus_tile / open_modal / close_modal /
            list_tiles / app_state

        Todo + project lifecycle:
          - tado_use_todo_create (optionally spawn_tile=true)
          - tado_use_todo_list / move / delete
          - tado_use_project_list / create / resolve / delete

        Eternal — AUTONOMOUS:
          - tado_use_eternal_start: kicks off architect, polls for crafted.md,
            AUTO-ACCEPTS the plan, returns once worker is running. Use this
            when the operator says "start an eternal in this project for
            <goal>" — no further confirmation needed.
          - tado_use_eternal_list / status / stop / intervene

        Dispatch — AUTONOMOUS:
          - tado_use_dispatch_start (same auto-accept pattern as eternal)
          - tado_use_dispatch_list / status

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

        Kanban:
          - tado_use_kanban_columns / move_card

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

    // MARK: - Stream parsing

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(0...newline)
            let line = String(data: Data(lineData), encoding: .utf8) ?? ""
            if line.isEmpty { continue }
            parseLine(line)
        }
    }

    private func consumeStderr(_ chunk: Data) {
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 64 * 1024 {
            stderrBuffer.removeFirst(stderrBuffer.count - 64 * 1024)
        }
    }

    /// Parse a single stream-json line. Both `claude -p
    /// --output-format stream-json` and `codex exec --output-format
    /// stream-json` emit one event per line. The shape we care
    /// about:
    ///
    ///   {"type":"system","subtype":"init","session_id":"…","model":"…"}
    ///   {"type":"stream_event","event":{"type":"content_block_start",
    ///     "content_block":{"type":"tool_use","id":"…","name":"…","input":{…}}}}
    ///   {"type":"stream_event","event":{"type":"content_block_delta",
    ///     "delta":{"type":"text_delta","text":"…"}}}
    ///   {"type":"assistant","message":{"content":[…]}}
    ///   {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"…","content":"…"}]}}
    ///   {"type":"result","duration_ms":…,"total_cost_usd":…,"usage":{"input_tokens":…,"output_tokens":…}}
    ///
    /// Unknown keys are ignored.
    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
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
                        markToolCall(id: id, output: body, status: .complete)
                    }
                }
            }
        case "assistant":
            // Final message envelope after streaming completes.
            // We've already accumulated text via stream_event deltas;
            // pick up any tool_use blocks we didn't see streamed.
            if let message = event["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        let input = compactJSON(block["input"]) ?? ""
                        upsertToolCall(id: id, name: name, input: input)
                    }
                }
            }
        case "result":
            if let usage = event["usage"] as? [String: Any] {
                if let inT = usage["input_tokens"] as? Int {
                    useState?.inputTokens += inT
                }
                if let outT = usage["output_tokens"] as? Int {
                    useState?.outputTokens += outT
                }
            }
        case "error":
            if let msg = event["message"] as? String {
                useState?.lastError = msg
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
                upsertToolCall(id: id, name: name, input: input)
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any] {
                let dtype = (delta["type"] as? String) ?? ""
                switch dtype {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        appendAssistantText(text)
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

    private func appendAssistantText(_ text: String) {
        guard let useState else { return }
        guard let i = useState.turns.indices.last,
              useState.turns[i].role == .assistant else { return }
        useState.turns[i].text += text
    }

    private func upsertToolCall(id: String, name: String, input: String) {
        guard let useState else { return }
        guard let i = useState.turns.indices.last,
              useState.turns[i].role == .assistant else { return }
        if let j = useState.turns[i].toolCalls.firstIndex(where: { $0.id == id }) {
            useState.turns[i].toolCalls[j].name = name
            useState.turns[i].toolCalls[j].input = input
        } else {
            useState.turns[i].toolCalls.append(
                TadoUseState.ToolCall(
                    id: id,
                    name: name,
                    input: input,
                    output: nil,
                    status: .pending
                )
            )
        }
    }

    private func markToolCall(id: String, output: String, status: TadoUseState.ToolCall.Status) {
        guard let useState else { return }
        guard let i = useState.turns.indices.last,
              useState.turns[i].role == .assistant else { return }
        guard let j = useState.turns[i].toolCalls.firstIndex(where: { $0.id == id }) else { return }
        useState.turns[i].toolCalls[j].output = output
        useState.turns[i].toolCalls[j].status = status
    }

    // MARK: - Termination + cleanup

    private func handleTermination(status: Int32) {
        stdoutSource?.cancel(); stdoutSource = nil
        stderrSource?.cancel(); stderrSource = nil

        if status != 0 {
            let trailing = String(data: stderrBuffer, encoding: .utf8) ?? ""
            let summary = trailing
                .split(separator: "\n")
                .last
                .map(String.init) ?? "exit_code=\(status)"
            useState?.lastError = "engine_exited: \(summary)"
        }
        finishLastAssistantTurn()
        useState?.isStreaming = false
        process = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
    }

    private func finishLastAssistantTurn() {
        guard let useState else { return }
        guard let i = useState.turns.indices.last,
              useState.turns[i].role == .assistant else { return }
        if useState.turns[i].finishedAt == nil {
            useState.turns[i].finishedAt = Date()
        }
    }

    // MARK: - MCP config generation

    /// Write a per-turn MCP config file with the three servers the
    /// agent should see. Lives under
    /// `<storage-root>/tado-use/mcp-configs/` and is cleaned up on
    /// teardown.
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
        let url = dir.appendingPathComponent("turn-\(UUID().uuidString).json")
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

    private func compactJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }
}
