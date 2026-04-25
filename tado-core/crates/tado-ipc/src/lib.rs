//! `tado-ipc` — Tado's file-based inter-agent IPC contract.
//!
//! Tado maintains a per-PID directory at `/tmp/tado-ipc-<pid>` with a
//! stable `/tmp/tado-ipc` symlink pointing at the current one. Every
//! running session gets a subdirectory under `sessions/<uuid>/` with
//! `inbox/`, `outbox/`, and `log`. External senders (like Dome's
//! Copy-to-Tado extension) drop message envelopes into
//! `a2a-inbox/<uuid>.msg`; the broker polls that dir and routes each
//! envelope into the target session's inbox.
//!
//! This crate is the Rust mirror of Swift's `IPCMessage.swift` and
//! `IPCSessionEntry` types plus a small set of path helpers.
//!
//! ## What's here (T2 scope)
//!
//! - [`message::IpcMessage`] / [`message::IpcSessionEntry`] — the
//!   JSON-on-disk types, byte-compatible with Swift. Serde `renameAll
//!   = "camelCase"` handles the Swift/JSON casing gap for the few
//!   fields that need it.
//! - [`paths::IpcPaths`] — canonical path derivation
//!   (`/tmp/tado-ipc` stable root + `/tmp/tado-ipc-<pid>` per-PID
//!   root + subdirs). Used by every future helper.
//! - [`outbound::write_external_message`] — write an envelope to
//!   `a2a-inbox/<uuid>.msg` atomically (tmp + rename). This is the
//!   same operation Dome's Copy-to-Tado extension performs in Swift
//!   today; exposing it here means future non-Swift callers (a
//!   future CLI, another Rust extension) share one implementation.
//!
//! ## What's deferred
//!
//! - The broker loop itself (file watcher, delivery into sessions'
//!   inboxes, registry.json maintenance, CLI shell-script
//!   generation). These still live in
//!   `Sources/Tado/Services/IPCBroker.swift`; porting them is a
//!   separate phase once we have a parallel Rust runtime to host
//!   the watcher. The Swift broker keeps working unchanged in the
//!   meantime.

pub mod events_socket;
pub mod message;
pub mod outbound;
pub mod paths;
pub mod registry;

pub use events_socket::{publish as publish_event, start as start_events_server, EventsError};
pub use message::{IpcMessage, IpcMessageStatus, IpcSessionEntry};
pub use outbound::{write_external_message, OutboundError};
pub use paths::IpcPaths;
pub use registry::{read_entries as read_registry, write_entries as write_registry, RegistryError};
