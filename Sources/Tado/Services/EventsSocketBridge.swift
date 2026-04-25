import Foundation
import CTadoCore

/// A6 — Bridge between Swift's `EventBus` and the Rust-hosted
/// real-time event socket (`tado_events_start` / `tado_events_publish`).
///
/// Purpose
/// -------
/// The durable NDJSON log (`events/current.ndjson`) owned by
/// `EventPersister` is authoritative for history. It's not
/// well-suited to low-latency fan-out — agents running inside Tado
/// terminal tiles would have to tail the file and re-parse it to
/// react to activity elsewhere. This bridge exposes every event
/// `EventBus` publishes on a Unix-domain socket at
/// `/tmp/tado-ipc-<pid>/events.sock` (stable-symlinked via
/// `/tmp/tado-ipc/events.sock`) so a subscriber can receive each
/// event as a JSON line within milliseconds of publish.
///
/// Use cases
/// ---------
/// - An agent subscribes to `session:<id>` and reacts to
///   `terminal.spawned` / `terminal.completed` events fired by
///   another tile.
/// - The Cross-Run Browser extension (C6) subscribes to `eternal:*`
///   and re-renders its timeline live.
/// - External scripts subscribe to `*` for observability without
///   having to parse NDJSON.
///
/// Failure mode
/// ------------
/// If `tado_events_start` fails (bind error, stale socket we can't
/// remove, no tokio), the bridge silently downgrades: the deliverer
/// still calls `tado_events_publish`, which is a no-op when the
/// server isn't live. The rest of the app is unaffected.
enum EventsSocketBridge {
    /// Call once at app launch. Starts the Rust listener on the
    /// per-PID path and registers an `EventBus` deliverer that
    /// forwards every event to the socket.
    @MainActor
    static func install() {
        let path = socketPath()
        // Parent dir will also be created by `IPCBroker` once
        // ContentView.onAppear fires, but we need it *now* so the
        // socket file's parent exists; Rust's start() creates it
        // idempotently too, but creating here means the Swift side
        // can set permissions immediately if needed.
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let status = path.withCString { cstr in
            tado_events_start(cstr)
        }
        guard status == 0 else {
            NSLog("tado-events: failed to bind \(path) (status \(status))")
            return
        }

        EventBus.shared.addDeliverer { event in
            publish(event)
        }
    }

    /// `/tmp/tado-ipc-<pid>/events.sock` — same PID-suffix
    /// convention IPCBroker uses for everything else.
    private static func socketPath() -> String {
        "/tmp/tado-ipc-\(ProcessInfo.processInfo.processIdentifier)/events.sock"
    }

    /// Serialize a `TadoEvent` into a JSON payload and publish it.
    /// The payload intentionally lifts the session ID (when present)
    /// to a top-level `sessionID` field so the Rust server promotes
    /// it into the wire record's `session` field — this lets
    /// subscribers use `session:<id>` filters without having to
    /// remember every event schema.
    private static func publish(_ event: TadoEvent) {
        let kind = event.type
        var payload: [String: Any] = [
            "id": event.id.uuidString,
            "severity": event.severity.rawValue,
            "title": event.title,
            "body": event.body,
            "ts": ISO8601DateFormatter().string(from: event.ts),
        ]
        var src: [String: Any] = ["kind": event.source.kind]
        if let pid = event.source.projectID { src["projectID"] = pid.uuidString }
        if let pn = event.source.projectName { src["projectName"] = pn }
        if let rid = event.source.runID {
            src["runID"] = rid.uuidString
            // Lift into top-level so `session:<run-id>` filters work
            // against Eternal/Dispatch runs too.
            payload["sessionID"] = rid.uuidString
        }
        if let sid = event.source.sessionID {
            src["sessionID"] = sid.uuidString
            payload["sessionID"] = sid.uuidString
        }
        payload["source"] = src

        guard
            let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let jsonStr = String(data: json, encoding: .utf8)
        else {
            return
        }

        _ = kind.withCString { kindCstr in
            jsonStr.withCString { payloadCstr in
                tado_events_publish(kindCstr, payloadCstr)
            }
        }
    }
}
