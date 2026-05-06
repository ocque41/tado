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
]

// Map MCP tool name → ControlRequest kind.
let toolKindMap: [String: String] = [
    "tado_use_navigate": "tado_use.navigate",
    "tado_use_focus_tile": "tado_use.focus_tile",
    "tado_use_open_modal": "tado_use.open_modal",
    "tado_use_close_modal": "tado_use.close_modal",
    "tado_use_list_tiles": "tado_use.list_tiles",
    "tado_use_app_state": "tado_use.app_state",
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
