//! Shared modules for the coordinator-driven Tado CLIs. The five
//! binaries in this crate all import from this lib for:
//!
//! - `control_client` — Unix-socket client that talks to the
//!   running Tado app's `ControlSocketServer`. Length-prefixed
//!   JSON request/response, byte-compatible with the Swift side.
//! - `disk` — read-only access to the on-disk artifacts the app
//!   already maintains (`<storage-root>/projects.json`, run-dir
//!   `state.json` / `crafted.md`). Lets read-only CLI verbs
//!   answer without an IPC round-trip.
//! - `output` — human + machine output. JSON by default
//!   (machine-readable for the coordinator agent); `--human`
//!   pretty-prints; `--toon` emits AXI-style compact tables.
//!
//! No timeouts, no retries, no watchdogs (rule 1) — the client
//! fails fast with a clear "Tado is not running" message when
//! the socket isn't reachable. Coordinator polling cadence
//! lives in the agent's prompt, not the CLI.

pub mod control_client;
pub mod disk;
pub mod output;

pub use control_client::{call, ControlClientError};
pub use disk::{read_projects_index, ProjectIndexEntry};
pub use output::{print_json, print_response, OutputMode};
