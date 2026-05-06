// tado-use-bridge — stdio MCP server that proxies tool calls into
// the running Tado app's ControlSocketServer.
//
// Wire shape (MCP / JSON-RPC 2.0):
//   stdin  ← line-delimited JSON-RPC requests
//   stdout → line-delimited JSON-RPC responses (newline per response)
//   stderr → human-readable diagnostics
//
// Protocol implemented:
//   - initialize          → handshake, declare server name + version
//   - tools/list          → enumerate the six bridge tools
//   - tools/call          → forward to Tado's control socket
//   - notifications/*     → ignored (no-op on receive)
//
// Each `tools/call` body resolves Tado's stable IPC symlink at
// `/tmp/tado-ipc/control.sock`, opens a length-prefixed JSON
// connection (4-byte big-endian length + JSON body, matching
// ControlSocketServer.swift), sends a `ControlRequest` envelope
// with `kind = "tado_use.<tool>"`, reads exactly one response,
// closes. There is no persistent connection — every tool call is
// a fresh socket round-trip, mirroring `tado-eternal` /
// `tado-dispatch` semantics.
//
// Why Swift, not Rust:
//   - Tado's existing tado-mcp + dome-mcp are Rust because they
//     plug into bt-core's in-process daemon. This bridge proxies
//     JSON-over-Unix-socket — no Rust code to share. Keeping it in
//     Swift inside the same Package.swift means one build target,
//     one cargo-free dev loop, and the coordinator/control wire
//     types are already defined right here in Sources/Tado.
//   - The bridge target deliberately depends ONLY on Foundation —
//     no SwiftUI, no AppKit, no SwiftData — so it stays a tiny
//     stdio binary that can ship in `Tado.app/Contents/MacOS/`.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Logging

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - JSON helpers

func encodeJSON(_ value: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
}

func decodeJSON(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
}

// MARK: - JSON-RPC framing on stdin

/// Persistent line buffer. `readLine()` keeps any bytes past the
/// newline so the next call doesn't have to re-read stdin first.
private var stdinBuffer = Data()

/// Reads one newline-terminated JSON-RPC line from stdin.
/// Returns nil on EOF.
func readLine() -> Data? {
    let stdin = FileHandle.standardInput
    while true {
        if let nl = stdinBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdinBuffer.prefix(upTo: nl))
            // Drop the consumed line + newline; keep the rest.
            stdinBuffer.removeSubrange(stdinBuffer.startIndex...nl)
            return line
        }
        let chunk = stdin.availableData
        if chunk.isEmpty {
            // EOF. If there's a final un-newlined line, hand it
            // back; otherwise signal end-of-stream.
            if stdinBuffer.isEmpty { return nil }
            let line = stdinBuffer
            stdinBuffer.removeAll()
            return line
        }
        stdinBuffer.append(chunk)
    }
}

func writeJSONRPCResponse(_ response: [String: Any]) {
    var data = encodeJSON(response)
    data.append(0x0A) // newline-delimited per MCP stdio convention
    FileHandle.standardOutput.write(data)
}

// MARK: - Control-socket client

/// Send one ControlRequest to the running Tado app over its
/// length-prefixed Unix socket. Returns the parsed response
/// envelope, or nil on connect / IO failure (with diagnostics on
/// stderr). Mirrors the wire format in
/// `Sources/Tado/Services/ControlSocketServer.swift`.
func sendControlRequest(kind: String, payload: [String: Any]) -> [String: Any]? {
    let socketPath = "/tmp/tado-ipc/control.sock"

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else {
        logStderr("tado-use-bridge: socket path too long")
        return nil
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst, src.baseAddress, pathBytes.count)
            }
        }
    }

    // Up to 3 connect attempts with 100 ms backoff — fresh fd per
    // attempt because a poisoned unix socket can't be re-connected.
    // The only retry in the codebase that's allowed under the
    // "no watchdog" rule because it's a local-IPC connect race
    // (Tado launching), not a dispatch-chain auto-retry.
    var fd: Int32 = -1
    for attempt in 0..<3 {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            if attempt == 2 {
                logStderr("tado-use-bridge: socket() failed")
                return nil
            }
            usleep(100_000)
            continue
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { break }
        let savedErrno = errno
        let errMsg = String(cString: strerror(savedErrno))
        logStderr("tado-use-bridge: connect attempt \(attempt + 1) failed: \(errMsg) (errno=\(savedErrno))")
        close(fd)
        fd = -1
        if attempt == 2 { break }
        usleep(100_000)
    }
    if fd < 0 {
        logStderr("tado-use-bridge: connect() failed after retries — Tado not running?")
        return nil
    }
    defer { close(fd) }

    let requestID = UUID().uuidString
    let request: [String: Any] = [
        "request_id": requestID,
        "kind": kind,
        "payload": payload,
    ]
    let body = encodeJSON(request)
    var header = [UInt8](repeating: 0, count: 4)
    let length = UInt32(body.count)
    header[0] = UInt8((length >> 24) & 0xFF)
    header[1] = UInt8((length >> 16) & 0xFF)
    header[2] = UInt8((length >> 8) & 0xFF)
    header[3] = UInt8(length & 0xFF)

    // `&header[sent]` to a syscall is unsafe in Swift — Array's
    // inout subscript can yield a pointer into a temporary buffer
    // not stable across the call. Use `withUnsafeBufferPointer` to
    // pin the storage, then offset with `advanced(by:)`.
    let headerOK = header.withUnsafeBufferPointer { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        var sent = 0
        while sent < 4 {
            let n = send(fd, base.advanced(by: sent), 4 - sent, 0)
            if n <= 0 {
                logStderr("tado-use-bridge: send(header) failed: \(String(cString: strerror(errno)))")
                return false
            }
            sent += n
        }
        return true
    }
    if !headerOK { return nil }

    let writeOK = body.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        guard let base = buf.baseAddress else { return false }
        var written = 0
        while written < body.count {
            let n = send(fd, base.advanced(by: written), body.count - written, 0)
            if n <= 0 {
                logStderr("tado-use-bridge: send(body) failed: \(String(cString: strerror(errno)))")
                return false
            }
            written += n
        }
        return true
    }
    if !writeOK { return nil }

    // Read the 4-byte response length.
    var lenBuf = [UInt8](repeating: 0, count: 4)
    var read = 0
    let lenOK = lenBuf.withUnsafeMutableBufferPointer { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        while read < 4 {
            let n = recv(fd, base.advanced(by: read), 4 - read, 0)
            if n <= 0 { return false }
            read += n
        }
        return true
    }
    if !lenOK {
        return ["__bridge_short_read__": true]
    }
    let respLen = (UInt32(lenBuf[0]) << 24)
        | (UInt32(lenBuf[1]) << 16)
        | (UInt32(lenBuf[2]) << 8)
        | UInt32(lenBuf[3])
    guard respLen > 0, respLen <= 4 * 1024 * 1024 else { return nil }

    var respBody = [UInt8](repeating: 0, count: Int(respLen))
    var got = 0
    let bodyOK = respBody.withUnsafeMutableBufferPointer { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        while got < Int(respLen) {
            let n = recv(fd, base.advanced(by: got), Int(respLen) - got, 0)
            if n <= 0 { return false }
            got += n
        }
        return true
    }
    if !bodyOK { return nil }

    return decodeJSON(Data(respBody))
}

// MARK: - Tool definitions

let toolList: [[String: Any]] = [
    [
        "name": "tado_use_navigate",
        "description": "Switch the main Tado window to one of its top-level views: details (live status dashboard), canvas (the tile grid), projects, todos, extensions.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "view": [
                    "type": "string",
                    "enum": ["details", "canvas", "projects", "todos", "extensions"],
                    "description": "Which view to navigate to.",
                ],
            ],
            "required": ["view"],
        ],
    ],
    [
        "name": "tado_use_focus_tile",
        "description": "Focus a specific terminal tile on the canvas. Identify it by todo_id (UUID) or grid coordinates ('col,row', 1-indexed).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "todo_id": ["type": "string", "description": "UUID of the todo / tile to focus."],
                "grid": ["type": "string", "description": "Grid coords like '1,1' or '[2,3]'."],
            ],
        ],
    ],
    [
        "name": "tado_use_open_modal",
        "description": "Open one of the main-window modal sheets / drawers: settings, new_project, done_list, trash_list, sidebar, tado_use.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["settings", "new_project", "done_list", "trash_list", "sidebar", "tado_use"],
                ],
            ],
            "required": ["kind"],
        ],
    ],
    [
        "name": "tado_use_close_modal",
        "description": "Close one of the main-window modal sheets / drawers (same kinds as open_modal).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["settings", "new_project", "done_list", "trash_list", "sidebar", "tado_use"],
                ],
            ],
            "required": ["kind"],
        ],
    ],
    [
        "name": "tado_use_list_tiles",
        "description": "List active terminal tiles with status, project, team, agent, model, and grid position. Filter by project_id (UUID) or status (pending/running/needsInput/awaitingResponse/completed/failed).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project_id": ["type": "string"],
                "status": ["type": "string"],
            ],
        ],
    ],
    [
        "name": "tado_use_app_state",
        "description": "Snapshot the live Tado UI state: current view, sidebar/drawer open flags, active project id, focused tile id, session counts by status, and any open modal.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
        ],
    ],

    // ─── Todo lifecycle ──────────────────────────────────────────
    [
        "name": "tado_use_todo_create",
        "description": "Create a new todo. If `spawn_tile` is true, also spawns a terminal tile that runs the configured engine (Claude/Codex) on the todo text. Use `project` (name) or `project_id` (UUID) to attach the todo to a project.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Todo prompt text (will become the spawned agent's first prompt if spawn_tile is true)."],
                "project": ["type": "string", "description": "Project name (substring match)."],
                "project_id": ["type": "string", "description": "Project UUID."],
                "spawn_tile": ["type": "boolean", "description": "If true, spawn a tile immediately. Default false."],
                "agent": ["type": "string", "description": "Optional .claude/agents/<name> subagent to run."],
                "team": ["type": "string", "description": "Optional team name within the project."],
            ],
            "required": ["text"],
        ],
    ],
    [
        "name": "tado_use_todo_list",
        "description": "List todos filtered by project + listState (active/done/trashed).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
                "state": ["type": "string", "enum": ["active", "done", "trashed"]],
            ],
        ],
    ],
    [
        "name": "tado_use_todo_move",
        "description": "Move a todo between active/done/trashed lists.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "todo_id": ["type": "string"],
                "to_state": ["type": "string", "enum": ["active", "done", "trashed"]],
            ],
            "required": ["todo_id", "to_state"],
        ],
    ],
    [
        "name": "tado_use_todo_delete",
        "description": "Permanently delete a todo (hard delete; bypasses trash).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "todo_id": ["type": "string"],
            ],
            "required": ["todo_id"],
        ],
    ],

    // ─── Project mgmt ────────────────────────────────────────────
    [
        "name": "tado_use_project_list",
        "description": "List all projects (id, name, root_path, created_at).",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "tado_use_project_create",
        "description": "Register a new Tado project. Requires an absolute filesystem path that exists on disk.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "root_path": ["type": "string", "description": "Absolute filesystem path to the project root."],
            ],
            "required": ["name", "root_path"],
        ],
    ],
    [
        "name": "tado_use_project_resolve",
        "description": "Resolve a project name (case-insensitive, substring match) to its full record. Errors with 'not_found' if no match.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
            ],
            "required": ["name"],
        ],
    ],
    [
        "name": "tado_use_project_delete",
        "description": "DESTRUCTIVE: delete a project. Terminates every running tile in the project, cleans up perf-baselines, removes the SwiftData record. Does NOT delete the on-disk filesystem at root_path.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
            ],
        ],
    ],

    // ─── Eternal — autonomous ────────────────────────────────────
    [
        "name": "tado_use_eternal_start",
        "description": "AUTONOMOUS: kick off an Eternal run end-to-end. Creates a coordinator marker todo, proposes the run (spawns the architect), polls the architect's progress for up to 180s, auto-accepts crafted.md on the operator's behalf, and returns once the worker is running. The architect's plan is auto-approved — use this when the operator has said 'just do it.' Returns architect_pending=true if architect is still running at timeout (caller should poll status).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "Project name (substring match)."],
                "project_id": ["type": "string"],
                "goal": ["type": "string", "description": "What the eternal should accomplish — becomes the user-brief the architect plans against."],
                "mode": ["type": "string", "enum": ["sprint", "mega"], "description": "sprint = per-iteration short bursts; mega = one long session. Default sprint."],
                "engine": ["type": "string", "enum": ["claude", "codex"], "description": "Which CLI runs the worker. Defaults to project's engine setting."],
                "label": ["type": "string", "description": "Optional human label for the run."],
            ],
            "required": ["goal"],
        ],
    ],
    [
        "name": "tado_use_eternal_list",
        "description": "List eternal runs filtered by project + state (drafted, planning, awaitingReview, ready, running, stopped, failed).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
                "state": ["type": "string"],
            ],
        ],
    ],
    [
        "name": "tado_use_eternal_status",
        "description": "Get full status for one eternal run: state, mode, engine, phase, iterations, sprints, last progress note, has_crafted, is_active.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "run_id": ["type": "string"],
            ],
            "required": ["run_id"],
        ],
    ],
    [
        "name": "tado_use_eternal_stop",
        "description": "Request stop on a running eternal. The Stop hook picks this up after the worker's next turn.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "run_id": ["type": "string"],
            ],
            "required": ["run_id"],
        ],
    ],
    [
        "name": "tado_use_eternal_intervene",
        "description": "Drop a directive into a running eternal worker's inbox. The worker picks it up on its next iteration. Use this to course-correct mid-flight without stopping the run.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "run_id": ["type": "string"],
                "directive": ["type": "string", "description": "Markdown body to write into the inbox."],
            ],
            "required": ["run_id", "directive"],
        ],
    ],

    // ─── Dispatch — autonomous ───────────────────────────────────
    [
        "name": "tado_use_dispatch_start",
        "description": "AUTONOMOUS: kick off a Dispatch run end-to-end. Creates coordinator marker todo, proposes the run (spawns architect), polls for crafted.md (up to 240s), auto-accepts the multi-phase plan, and returns once phase 1 is running. Same auto-approve semantics as eternal_start.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
                "goal": ["type": "string", "description": "Dispatch brief — what the architect should plan a multi-phase delivery against."],
                "label": ["type": "string"],
            ],
            "required": ["goal"],
        ],
    ],
    [
        "name": "tado_use_dispatch_list",
        "description": "List dispatch runs filtered by project + state.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
                "state": ["type": "string"],
            ],
        ],
    ],
    [
        "name": "tado_use_dispatch_status",
        "description": "Get status for one dispatch run.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "run_id": ["type": "string"],
            ],
            "required": ["run_id"],
        ],
    ],

    // ─── Bootstraps ──────────────────────────────────────────────
    [
        "name": "tado_use_bootstrap",
        "description": "Run one of the four project bootstraps as a one-shot tile: a2a (install Tado A2A docs into the project's CLAUDE.md/AGENTS.md), team (re-inject team awareness — needs teams to exist), auto-mode (configure Claude auto-permission settings + project local), knowledge (teach the project's agents about Dome).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["a2a", "team", "auto-mode", "knowledge"]],
                "project": ["type": "string"],
                "project_id": ["type": "string"],
            ],
            "required": ["kind"],
        ],
    ],

    // ─── Settings ────────────────────────────────────────────────
    [
        "name": "tado_use_settings_get",
        "description": "Read the full GlobalSettings (engine defaults, UI prefs, canvas layout, notification routing, Dome config) as a JSON object.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "tado_use_settings_set",
        "description": "Write a single global setting by dotted path. Supported keys: engine.default, engine.claude.{model,mode,effort}, engine.codex.{model,mode,effort}, ui.{defaultThemeId,bellMode,terminalFontFamily,terminalFontSize,cursorBlink,randomTileColor}, canvas.gridColumns, dome.{defaultKnowledgeScope,defaultKnowledgeKind,includeGlobalInProject,agentRegistrationEnabled}, notifications.retentionDays. Pass numbers/booleans as their string form.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "Dotted setting path."],
                "value": ["type": "string", "description": "New value as a string. Numbers/booleans accepted as their string form."],
            ],
            "required": ["key", "value"],
        ],
    ],

    // ─── Dome ────────────────────────────────────────────────────
    [
        "name": "tado_use_dome_ingest_codebase",
        "description": "Register a project's codebase with Dome's tree-sitter indexer, kick off a full or incremental index in the background, and (by default) start the file watcher that keeps it fresh. Pass either a Tado project (name/project_id) or an arbitrary root_path.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
                "root_path": ["type": "string", "description": "Absolute path to the codebase root (alternative to passing a Tado project)."],
                "name": ["type": "string", "description": "Display name when ingesting by root_path."],
                "watch": ["type": "boolean", "description": "Default true — start a live file-watcher to re-index on change."],
                "full_rebuild": ["type": "boolean", "description": "Default false — true forces a full re-index instead of incremental."],
            ],
        ],
    ],
    [
        "name": "tado_use_dome_code_status",
        "description": "List every codebase Dome has registered for indexing: file_count, chunk_count, embedding_model, last_full_index_at, watching flag.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "tado_use_dome_code_search",
        "description": "Hybrid (vector + lexical) search across indexed code chunks. Returns ranked hits with file path, language, qualified symbol name, line range, and excerpt.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "project_id": ["type": "string", "description": "Limit to a specific Dome project id."],
                "limit": ["type": "string", "description": "Max hits to return (default 10)."],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "tado_use_dome_note_create",
        "description": "Write a knowledge note into Dome's vault. Defaults to global scope, user.md side, knowledge kind. Returns the new note id.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "topic": ["type": "string", "description": "Default 'tado-use'."],
                "kind": ["type": "string", "description": "knowledge | decision | intent | outcome | retro. Default 'knowledge'."],
                "scope": ["type": "string", "enum": ["global", "project"], "description": "Default global."],
            ],
            "required": ["body"],
        ],
    ],
    [
        "name": "tado_use_dome_note_search",
        "description": "Search Dome notes with hybrid scoring. Returns ranked hits (note_id, title, topic, score).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "limit": ["type": "string"],
            ],
            "required": ["query"],
        ],
    ],
    [
        "name": "tado_use_dome_recipe_apply",
        "description": "Run a retrieval recipe (governed answer with citations + missing-authority list). Three baked recipes ship: architecture-review, completion-claim, team-handoff. Per-project overrides go in <project>/.tado/verified-prompts/<intent>.md.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "intent": ["type": "string", "description": "e.g. architecture-review, completion-claim, team-handoff."],
                "project_id": ["type": "string"],
            ],
            "required": ["intent"],
        ],
    ],
    [
        "name": "tado_use_dome_agent_status",
        "description": "Snapshot Dome's agent operations feed (running statuses, recent context events, available context packs).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": ["type": "string"],
            ],
        ],
    ],

    // ─── Kanban ──────────────────────────────────────────────────
    [
        "name": "tado_use_kanban_columns",
        "description": "List Kanban columns for a project (column_key, title, order_index).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string"],
                "project_id": ["type": "string"],
            ],
        ],
    ],
    [
        "name": "tado_use_kanban_move_card",
        "description": "Move a todo to a Kanban column (or remove it from the board by passing empty column_key).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "todo_id": ["type": "string"],
                "column_key": ["type": "string", "description": "Target column's key. Empty/omitted to remove from the board."],
            ],
            "required": ["todo_id"],
        ],
    ],

    // ─── Extensions ──────────────────────────────────────────────
    [
        "name": "tado_use_extension_list",
        "description": "List every registered Tado extension (id, display_name, short_description, icon, version).",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "tado_use_extension_open",
        "description": "Request that an extension's window be opened. Publishes a `tado_use.openExtension` event the running app reacts to. Valid ids: notifications, dome, cross-run-browser.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "enum": ["notifications", "dome", "cross-run-browser"]],
            ],
            "required": ["id"],
        ],
    ],

    // ─── Notifications + tile control ───────────────────────────
    [
        "name": "tado_use_notify",
        "description": "Publish a Tado notification — fires the dock badge, in-app banner, system notification, sound, and NDJSON event log per the user's notification routing.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "severity": ["type": "string", "enum": ["info", "success", "warning", "error"]],
            ],
            "required": ["title"],
        ],
    ],
    [
        "name": "tado_use_tile_send",
        "description": "Send text to a running terminal tile. Target by todo_id (UUID), session_id (UUID), grid coords ('1,1'), or name substring.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string"],
                "message": ["type": "string"],
            ],
            "required": ["target", "message"],
        ],
    ],
    [
        "name": "tado_use_tile_read",
        "description": "Read the last N lines of output from a running tile. Default tail=100.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string"],
                "tail": ["type": "string", "description": "Number of trailing lines to return."],
            ],
            "required": ["target"],
        ],
    ],
    [
        "name": "tado_use_tile_terminate",
        "description": "Terminate a running tile.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string"],
            ],
            "required": ["target"],
        ],
    ],
    [
        "name": "tado_use_events_query",
        "description": "Query the in-memory event ring buffer (last 500 events). Filter by type prefix.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "type_prefix": ["type": "string", "description": "Match events whose type starts with this prefix."],
                "limit": ["type": "string"],
            ],
        ],
    ],
]

// Map MCP tool name → ControlRequest kind.
let toolKindMap: [String: String] = [
    "tado_use_navigate": "tado_use.navigate",
    "tado_use_focus_tile": "tado_use.focus_tile",
    "tado_use_open_modal": "tado_use.open_modal",
    "tado_use_close_modal": "tado_use.close_modal",
    "tado_use_list_tiles": "tado_use.list_tiles",
    "tado_use_app_state": "tado_use.app_state",

    "tado_use_todo_create": "tado_use.todo_create",
    "tado_use_todo_list": "tado_use.todo_list",
    "tado_use_todo_move": "tado_use.todo_move",
    "tado_use_todo_delete": "tado_use.todo_delete",

    "tado_use_project_list": "tado_use.project_list",
    "tado_use_project_create": "tado_use.project_create",
    "tado_use_project_resolve": "tado_use.project_resolve",
    "tado_use_project_delete": "tado_use.project_delete",

    "tado_use_eternal_start": "tado_use.eternal_start",
    "tado_use_eternal_list": "tado_use.eternal_list",
    "tado_use_eternal_status": "tado_use.eternal_status",
    "tado_use_eternal_stop": "tado_use.eternal_stop",
    "tado_use_eternal_intervene": "tado_use.eternal_intervene",

    "tado_use_dispatch_start": "tado_use.dispatch_start",
    "tado_use_dispatch_list": "tado_use.dispatch_list",
    "tado_use_dispatch_status": "tado_use.dispatch_status",

    "tado_use_bootstrap": "tado_use.bootstrap",

    "tado_use_settings_get": "tado_use.settings_get",
    "tado_use_settings_set": "tado_use.settings_set",

    "tado_use_dome_ingest_codebase": "tado_use.dome_ingest_codebase",
    "tado_use_dome_code_status": "tado_use.dome_code_status",
    "tado_use_dome_code_search": "tado_use.dome_code_search",
    "tado_use_dome_note_create": "tado_use.dome_note_create",
    "tado_use_dome_note_search": "tado_use.dome_note_search",
    "tado_use_dome_recipe_apply": "tado_use.dome_recipe_apply",
    "tado_use_dome_agent_status": "tado_use.dome_agent_status",

    "tado_use_kanban_columns": "tado_use.kanban_columns",
    "tado_use_kanban_move_card": "tado_use.kanban_move_card",

    "tado_use_extension_list": "tado_use.extension_list",
    "tado_use_extension_open": "tado_use.extension_open",

    "tado_use_notify": "tado_use.notify",
    "tado_use_tile_send": "tado_use.tile_send",
    "tado_use_tile_read": "tado_use.tile_read",
    "tado_use_tile_terminate": "tado_use.tile_terminate",
    "tado_use_events_query": "tado_use.events_query",
]

// MARK: - JSON-RPC handlers

func handleInitialize(_ id: Any?) -> [String: Any] {
    return [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "result": [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:] as [String: Any],
            ],
            "serverInfo": [
                "name": "tado-use-bridge",
                "version": "1.0.0",
            ],
        ],
    ]
}

func handleToolsList(_ id: Any?) -> [String: Any] {
    return [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "result": [
            "tools": toolList,
        ],
    ]
}

func handleToolsCall(_ id: Any?, params: [String: Any]?) -> [String: Any] {
    guard let params,
          let toolName = params["name"] as? String else {
        return jsonRpcError(id: id, code: -32602, message: "missing tool name")
    }
    guard let kind = toolKindMap[toolName] else {
        return jsonRpcError(id: id, code: -32601, message: "unknown tool '\(toolName)'")
    }
    let arguments = (params["arguments"] as? [String: Any]) ?? [:]
    guard let response = sendControlRequest(kind: kind, payload: arguments) else {
        return jsonRpcError(
            id: id,
            code: -32000,
            message: "Tado control socket unreachable. Is the Tado app running?"
        )
    }
    if response["__bridge_short_read__"] as? Bool == true {
        return jsonRpcError(
            id: id,
            code: -32000,
            message: "Tado control socket closed without responding. The running app may be a build that predates the Tado Use bridge — relaunch from a fresh build."
        )
    }

    // ControlResponseEnvelope on the wire:
    //   {"request_id":"...", "ok":bool, "data":{...}|null, "error":string|null}
    let ok = (response["ok"] as? Bool) ?? false
    if !ok {
        let errCode = (response["error"] as? String) ?? "unknown_error"
        let dataDict = response["data"] as? [String: Any]
        let humanMsg = (dataDict?["message"] as? String) ?? errCode
        return jsonRpcError(id: id, code: -32000, message: "\(errCode): \(humanMsg)")
    }
    let data = response["data"] ?? [String: Any]()
    let payloadJSON: String = {
        if let s = data as? String { return s }
        if let d = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{}"
    }()
    return [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": payloadJSON,
                ],
            ],
        ],
    ]
}

func jsonRpcError(id: Any?, code: Int, message: String) -> [String: Any] {
    return [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "error": [
            "code": code,
            "message": message,
        ],
    ]
}

// MARK: - Main loop

logStderr("tado-use-bridge: ready (stdio MCP)")

while let lineData = readLine() {
    guard let request = decodeJSON(lineData) else {
        let resp = jsonRpcError(id: nil, code: -32700, message: "parse error")
        writeJSONRPCResponse(resp)
        continue
    }
    let method = (request["method"] as? String) ?? ""
    let id = request["id"]

    // Notifications carry no id; we ignore everything except the
    // small set of methods MCP requires.
    let response: [String: Any]?
    switch method {
    case "initialize":
        response = handleInitialize(id)
    case "tools/list":
        response = handleToolsList(id)
    case "tools/call":
        response = handleToolsCall(id, params: request["params"] as? [String: Any])
    case "notifications/initialized",
         "notifications/cancelled":
        response = nil
    default:
        if id != nil {
            response = jsonRpcError(id: id, code: -32601, message: "method not found: \(method)")
        } else {
            response = nil
        }
    }
    if let response { writeJSONRPCResponse(response) }
}
