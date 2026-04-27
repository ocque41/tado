//! A6 — Side-channel real-time A2A event socket.
//!
//! A lightweight Unix-domain socket that complements the durable
//! NDJSON event log Tado's Swift `EventBus` already maintains. The
//! persistence layer is authoritative for history; this socket exists
//! so agents inside terminal tiles can *react* to events within
//! milliseconds of them happening instead of polling the log.
//!
//! ## Protocol (line-delimited, UTF-8)
//!
//! After connecting, a client sends exactly one `SUBSCRIBE` line:
//!
//! ```text
//! SUBSCRIBE <filter>
//! ```
//!
//! The server replies:
//!
//! ```text
//! {"type":"subscribed","filter":"<filter>"}
//! ```
//!
//! From then on, the server pushes one JSON object per line for every
//! event whose payload matches the filter. The client may close the
//! connection at any time; no unsubscribe message is required.
//!
//! ### Filters
//!
//! - `*` — everything (firehose)
//! - `topic:<name>` — events whose `kind` starts with `topic:<name>`
//! - `session:<id>` — events whose `session` field equals `<id>`
//! - `spawn:*` — events whose `kind` starts with `spawn:`
//! - `<kind-prefix>` — any event whose `kind` field starts with the
//!   given prefix (catch-all for future event families)
//!
//! ## Event shape
//!
//! Events are freeform JSON dictionaries containing at least `kind` and
//! `ts`. Callers pass `kind` as a string and `payload` as a JSON value;
//! the server composes the wire record:
//!
//! ```text
//! {
//!   "ts": "2026-04-22T12:34:56.789Z",
//!   "kind": "terminal.spawned",
//!   "session": "<uuid-if-present>",
//!   "payload": { ... original payload ... }
//! }
//! ```
//!
//! If `payload` contains `"session_id"` or `"sessionID"`, the server
//! lifts it into the top-level `session` field so `session:<id>`
//! filters work without clients having to know every event schema.
//!
//! ## Threading
//!
//! A private `tokio::runtime::Runtime` is lazily created on first
//! `start(...)` call and lives for the process lifetime. A single
//! `tokio::sync::broadcast::Sender<String>` fans every published
//! event out to every subscriber task. Each accepted connection
//! spawns its own reader+writer task pair; filtering happens
//! client-side inside that task so slow subscribers never block fast
//! ones (the broadcast channel has per-subscriber buffering; lagged
//! subscribers silently skip events they couldn't drain).
//!
//! ## Safety invariants
//!
//! - `start` is idempotent: second call is a no-op (returns `Ok`).
//! - Publishing before `start` is silently dropped. Callers shouldn't
//!   care — the Swift `EventBus` deliverer wires itself up after the
//!   FFI start call anyway.

use std::io;
use std::path::Path;
use std::sync::OnceLock;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::broadcast;

/// Broadcast channel capacity. 1024 is roomy enough that an idle or
/// lagging subscriber can miss a short burst (hundreds of events) and
/// still recover; a subscriber that hasn't drained in 1024 events is
/// misbehaving and gets auto-dropped by tokio's broadcast semantics.
const BROADCAST_CAPACITY: usize = 1024;

/// Process-wide runtime hosting the accept loop + per-connection
/// tasks. Kept on its own runtime (not shared with Dome's) so the
/// events socket is independent of Dome being booted.
static EVENTS_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Fanout channel. `None` before `start`; `Some` once the listener is
/// bound. Publishes before start are dropped silently.
static EVENTS_TX: OnceLock<broadcast::Sender<String>> = OnceLock::new();

/// Server errors surfaced to the FFI layer.
#[derive(Debug, thiserror::Error)]
pub enum EventsError {
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
    #[error("runtime build error: {0}")]
    Runtime(String),
}

/// Start the events socket listener at `socket_path`. Idempotent — a
/// second call with any path is a silent no-op and returns `Ok`.
///
/// Removes a stale socket file at the given path before binding, so
/// restarts after a crash-without-cleanup don't fail with EADDRINUSE.
pub fn start(socket_path: impl AsRef<Path>) -> Result<(), EventsError> {
    if EVENTS_TX.get().is_some() {
        return Ok(());
    }

    let path = socket_path.as_ref().to_path_buf();

    let runtime = EVENTS_RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("tado-events")
            .enable_all()
            .build()
            .expect("tokio events runtime")
    });

    // Clean up a stale socket from a previous run. Ignore "not found".
    match std::fs::remove_file(&path) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(EventsError::Io(e)),
    }

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(EventsError::Io)?;
    }

    let listener = std::os::unix::net::UnixListener::bind(&path).map_err(EventsError::Io)?;
    listener.set_nonblocking(true).map_err(EventsError::Io)?;
    let listener = runtime
        .block_on(async { UnixListener::from_std(listener) })
        .map_err(EventsError::Io)?;

    let (tx, _) = broadcast::channel::<String>(BROADCAST_CAPACITY);
    EVENTS_TX
        .set(tx.clone())
        .expect("EVENTS_TX set exactly once");

    runtime.spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    let sub_rx = tx.subscribe();
                    tokio::spawn(handle_connection(stream, sub_rx));
                }
                Err(e) => {
                    eprintln!("tado-events: accept error: {e}");
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                }
            }
        }
    });

    Ok(())
}

/// Compose a wire record and broadcast to every subscriber.
/// Silently dropped if `start` hasn't run yet.
pub fn publish(kind: &str, payload: Value) {
    let Some(tx) = EVENTS_TX.get() else { return };
    let session = payload
        .get("session_id")
        .or_else(|| payload.get("sessionID"))
        .or_else(|| payload.get("session"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let record = json!({
        "ts": ts,
        "kind": kind,
        "session": session,
        "payload": payload,
    });
    let line = match serde_json::to_string(&record) {
        Ok(s) => s + "\n",
        Err(_) => return,
    };
    // Ignore "no subscribers" — publishes before the first client
    // connects are intentionally dropped.
    let _ = tx.send(line);
}

/// Per-connection loop: read the first line as a subscribe request,
/// then stream matching events until the peer closes or errors.
async fn handle_connection(stream: UnixStream, mut rx: broadcast::Receiver<String>) {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader).lines();

    let filter = match reader.next_line().await {
        Ok(Some(line)) => parse_subscribe(&line).unwrap_or_else(|| "*".to_string()),
        _ => return,
    };

    let ack = format!(
        "{}\n",
        json!({ "type": "subscribed", "filter": filter })
    );
    if writer.write_all(ack.as_bytes()).await.is_err() {
        return;
    }

    // Drive both peer-close detection and event delivery on the same
    // task. If the peer closes, `next_line()` returns Ok(None) and we
    // bail.
    loop {
        tokio::select! {
            event = rx.recv() => {
                match event {
                    Ok(line) => {
                        if matches_filter(&line, &filter)
                            && writer.write_all(line.as_bytes()).await.is_err()
                        {
                            return;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // Send a best-effort "you missed events" marker.
                        let marker = json!({
                            "type": "lagged",
                            "filter": filter,
                        }).to_string() + "\n";
                        let _ = writer.write_all(marker.as_bytes()).await;
                    }
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
            peer = reader.next_line() => {
                // Peer sent another line or closed. We don't accept
                // additional subscribes today — either ignore extra
                // lines or quit on EOF.
                match peer {
                    Ok(Some(_)) => { /* ignore chatter, keep streaming */ }
                    Ok(None) | Err(_) => return,
                }
            }
        }
    }
}

/// Extract the filter from a `SUBSCRIBE <filter>` line. Returns
/// `None` if the input is malformed; callers treat that as `*`.
fn parse_subscribe(line: &str) -> Option<String> {
    let trimmed = line.trim();
    let rest = trimmed.strip_prefix("SUBSCRIBE")?.trim_start();
    if rest.is_empty() {
        Some("*".to_string())
    } else {
        Some(rest.to_string())
    }
}

/// Return true if the given already-encoded JSON line should be
/// delivered to a subscriber with this filter. Parses the record
/// once per-test; cheap because records are short.
fn matches_filter(line: &str, filter: &str) -> bool {
    if filter == "*" {
        return true;
    }
    let record: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return false,
    };
    if let Some(rest) = filter.strip_prefix("session:") {
        return record
            .get("session")
            .and_then(|v| v.as_str())
            .map(|s| s == rest)
            .unwrap_or(false);
    }
    if let Some(rest) = filter.strip_prefix("topic:") {
        return record
            .get("kind")
            .and_then(|v| v.as_str())
            .map(|s| s == format!("topic:{rest}") || s.starts_with(&format!("topic:{rest}.")))
            .unwrap_or(false);
    }
    // Otherwise treat the filter as a raw prefix on `kind`.
    record
        .get("kind")
        .and_then(|v| v.as_str())
        .map(|s| s.starts_with(filter))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_matches_everything() {
        let line = r#"{"kind":"anything","session":null,"payload":{}}"#;
        assert!(matches_filter(line, "*"));
    }

    #[test]
    fn session_filter_exact_match() {
        let line = r#"{"kind":"x","session":"abc","payload":{}}"#;
        assert!(matches_filter(line, "session:abc"));
        assert!(!matches_filter(line, "session:xyz"));
    }

    #[test]
    fn topic_filter_matches_prefix_and_dot() {
        let line1 = r#"{"kind":"topic:planning","payload":{}}"#;
        let line2 = r#"{"kind":"topic:planning.detail","payload":{}}"#;
        let line3 = r#"{"kind":"topic:other","payload":{}}"#;
        assert!(matches_filter(line1, "topic:planning"));
        assert!(matches_filter(line2, "topic:planning"));
        assert!(!matches_filter(line3, "topic:planning"));
    }

    #[test]
    fn raw_prefix_filter() {
        let line = r#"{"kind":"spawn.foo","payload":{}}"#;
        assert!(matches_filter(line, "spawn"));
        assert!(!matches_filter(line, "terminal"));
    }

    #[test]
    fn parse_subscribe_handles_whitespace_and_wildcards() {
        assert_eq!(parse_subscribe("SUBSCRIBE *\n"), Some("*".to_string()));
        assert_eq!(
            parse_subscribe("SUBSCRIBE  session:abc\n"),
            Some("session:abc".to_string())
        );
        assert_eq!(parse_subscribe("SUBSCRIBE"), Some("*".to_string()));
        assert_eq!(parse_subscribe("GARBAGE foo"), None);
    }
}
