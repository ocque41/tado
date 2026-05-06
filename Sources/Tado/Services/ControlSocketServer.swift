import Foundation
import AppKit

/// Listens on a Unix domain socket at `/tmp/tado-ipc-<pid>/control.sock`
/// for synchronous request-response calls from external CLI clients
/// (`tado-eternal`, `tado-dispatch`, `tado-bootstrap`, `tado-system`).
///
/// Wire format: length-prefixed JSON. Each frame is a 4-byte
/// big-endian unsigned length, then exactly that many UTF-8 bytes of
/// JSON. Connections are short-lived: client connects, sends one
/// request, reads one response, closes.
///
/// Lifecycle:
///   1. App launches → IPCBroker.init() → starts ControlSocketServer.
///   2. Server binds the socket, writes `/tmp/tado-ipc/active-pid`
///      so clients can find the live app without scanning /tmp.
///   3. willTerminate → cleanup() unlinks the socket and removes
///      the active-pid file.
///
/// No timeout, no retry, no watchdog — clients fail fast if the
/// server is gone (rule 1). Server-side handlers are synchronous on
/// the main actor so SwiftData mutations stay safe.
@MainActor
@Observable
final class ControlSocketServer {
    private let ipcRoot: URL
    private let socketPath: String
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var ownsActivePidFile = false

    /// Called for every well-formed inbound request. The closure
    /// runs on the main actor (router invocations mutate SwiftData)
    /// and returns the response envelope synchronously. ContentView
    /// installs this callback once it has terminalManager +
    /// modelContext + appState in hand, mirroring the
    /// `onSpawnRequest` pattern in IPCBroker.
    @ObservationIgnored
    var onRequest: ((ControlRequest) -> ControlResponseEnvelope)?

    init(ipcRoot: URL) {
        self.ipcRoot = ipcRoot
        self.socketPath = ipcRoot
            .appendingPathComponent("control.sock")
            .path
    }

    /// Binds the listening socket and writes the active-pid file.
    /// Idempotent — if the socket file exists from a prior run we
    /// unlink it first (the prior pid is dead by definition; we
    /// hold the new pid).
    func start() {
        try? FileManager.default.createDirectory(
            at: ipcRoot,
            withIntermediateDirectories: true
        )

        // Pre-clean any leftover socket. macOS doesn't auto-unlink
        // unix sockets on process exit, so a force-quit can leave
        // a stale node here that would otherwise cause bind() to
        // fail with EADDRINUSE.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            NSLog("[Tado] ControlSocketServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            NSLog("[Tado] ControlSocketServer: socket path too long (\(pathBytes.count) > \(maxLen))")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            NSLog("[Tado] ControlSocketServer: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // 0o600: only the user that ran the app can connect. The
        // single-user laptop threat model assumes nobody else is
        // logged in concurrently; tightening permissions costs
        // nothing.
        chmod(socketPath, 0o600)

        if listen(fd, 16) != 0 {
            NSLog("[Tado] ControlSocketServer: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return
        }

        listenFd = fd

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.acceptOne()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        listenSource = source

        writeActivePidFile()

        NSLog("[Tado] ControlSocketServer listening at \(socketPath)")

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cleanup()
            }
        }
    }

    /// Unlinks the socket file and active-pid file. Called on
    /// willTerminate; safe to call multiple times.
    func cleanup() {
        listenSource?.cancel()
        listenSource = nil
        listenFd = -1
        unlink(socketPath)
        if ownsActivePidFile {
            try? FileManager.default.removeItem(at: StorePaths.activePidFile)
            ownsActivePidFile = false
        }
    }

    // MARK: - Connection handling

    private func acceptOne() {
        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(listenFd, &clientAddr, &clientLen)
        if clientFd < 0 { return }

        Task.detached { [weak self] in
            await self?.handleConnection(fd: clientFd)
        }
    }

    /// One-shot connection handler. Reads one request, dispatches,
    /// writes one response, closes. Runs off the main thread for
    /// the IO; the router invocation hops back to @MainActor.
    private nonisolated func handleConnection(fd: Int32) async {
        defer { close(fd) }

        guard let payload = readFrame(from: fd) else {
            // Don't bother replying — client gave us a malformed
            // header or hung up before sending the body.
            return
        }

        let response: Data
        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: payload)
            response = await dispatch(request: request)
        } catch {
            response = encodeError(
                requestID: nil,
                message: "decode_error: \(error.localizedDescription)"
            )
        }

        _ = writeFrame(response, to: fd)
    }

    private nonisolated func dispatch(request: ControlRequest) async -> Data {
        let result: ControlResponseEnvelope = await MainActor.run {
            guard let handler = self.onRequest else {
                return ControlResponseEnvelope(
                    requestID: request.requestID,
                    ok: false,
                    data: nil,
                    error: "router_unavailable"
                )
            }
            return handler(request)
        }
        return (try? JSONEncoder().encode(result)) ?? encodeError(
            requestID: request.requestID,
            message: "encode_error"
        )
    }

    private nonisolated func encodeError(requestID: String?, message: String) -> Data {
        let env = ControlResponseEnvelope(
            requestID: requestID ?? "",
            ok: false,
            data: nil,
            error: message
        )
        return (try? JSONEncoder().encode(env)) ?? Data()
    }

    // MARK: - Framing

    /// Reads a single 4-byte-length-prefixed frame off the socket.
    /// Returns nil on EOF or short read; the caller closes.
    private nonisolated func readFrame(from fd: Int32) -> Data? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        var read = 0
        while read < 4 {
            let n = recv(fd, &lenBuf[read], 4 - read, 0)
            if n <= 0 { return nil }
            read += n
        }
        let length = (UInt32(lenBuf[0]) << 24)
            | (UInt32(lenBuf[1]) << 16)
            | (UInt32(lenBuf[2]) << 8)
            | UInt32(lenBuf[3])
        // Cap at 4 MiB to stop a hostile client from asking us to
        // allocate gigabytes. Real coordinator payloads are < 100 KiB.
        guard length > 0, length <= 4 * 1024 * 1024 else { return nil }
        var body = [UInt8](repeating: 0, count: Int(length))
        var got = 0
        while got < Int(length) {
            let n = recv(fd, &body[got], Int(length) - got, 0)
            if n <= 0 { return nil }
            got += n
        }
        return Data(body)
    }

    private nonisolated func writeFrame(_ data: Data, to fd: Int32) -> Bool {
        let length = UInt32(data.count)
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        var sent = 0
        while sent < 4 {
            let n = send(fd, &header[sent], 4 - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            var written = 0
            while written < data.count {
                let n = send(fd, base.advanced(by: written), data.count - written, 0)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    // MARK: - active-pid

    private func writeActivePidFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bytes = "\(pid)\n".data(using: .utf8) ?? Data()
        do {
            try AtomicStore.write(bytes, to: StorePaths.activePidFile)
            ownsActivePidFile = true
        } catch {
            NSLog("[Tado] ControlSocketServer: active-pid write failed: \(error)")
        }
    }
}

// MARK: - Wire types

/// JSON envelope sent by the CLI client over the socket. The
/// `kind` field discriminates which handler in
/// `ControlRequestRouter` runs; payload is decoded by the handler
/// using its own typed shape.
struct ControlRequest: Codable {
    let requestID: String
    let kind: String
    let payload: ControlPayload?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case kind
        case payload
    }
}

/// Heterogeneous JSON value carried as the request payload. We
/// don't pre-decode into typed structs at this layer — handlers in
/// `ControlRequestRouter` reach into the underlying JSON dictionary
/// for the fields they need. Keeps the wire format extensible
/// without rev-locking the schema.
struct ControlPayload: Codable {
    let raw: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.raw = [:]
        } else {
            self.raw = try container.decode([String: AnyCodable].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    func string(_ key: String) -> String? {
        guard let v = raw[key] else { return nil }
        if case .string(let s) = v.value { return s }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let v = raw[key] else { return nil }
        if case .bool(let b) = v.value { return b }
        return nil
    }
}

/// Response envelope written back to the CLI. `data` is freeform
/// JSON; `error` is a short machine-readable code (e.g.
/// `state_mismatch`, `not_found`, `app_unresponsive`) plus an
/// optional human note in the data field.
struct ControlResponseEnvelope: Codable {
    let requestID: String
    let ok: Bool
    let data: AnyCodable?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ok
        case data
        case error
    }
}

/// Minimal AnyCodable: handles strings, numbers, bools, null,
/// arrays, and dicts. Used for both request payloads and response
/// `data`. Avoids pulling in a third-party crate; the surface we
/// need here is small.
struct AnyCodable: Codable {
    enum Value {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case object([String: AnyCodable])
    }
    let value: Value

    init(_ value: Value) { self.value = value }
    init(_ string: String) { self.value = .string(string) }
    init(_ int: Int) { self.value = .int(Int64(int)) }
    init(_ bool: Bool) { self.value = .bool(bool) }
    init(_ dict: [String: AnyCodable]) { self.value = .object(dict) }
    init(_ arr: [AnyCodable]) { self.value = .array(arr) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = .null
        } else if let b = try? c.decode(Bool.self) {
            self.value = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self.value = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self.value = .double(d)
        } else if let s = try? c.decode(String.self) {
            self.value = .string(s)
        } else if let a = try? c.decode([AnyCodable].self) {
            self.value = .array(a)
        } else if let o = try? c.decode([String: AnyCodable].self) {
            self.value = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "AnyCodable: unsupported JSON type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
