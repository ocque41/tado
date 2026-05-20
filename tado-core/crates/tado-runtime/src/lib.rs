//! CLI-owned Tado runtime.
//!
//! `tadod` is a profile-isolated daemon that owns PTY sessions, a local
//! SQLite runtime store, and a versioned Unix-socket protocol. It is the
//! backing runtime for the standalone `tado` CLI/TUI path. The macOS desktop
//! app remains on its existing Swift services unless it explicitly opts into
//! this daemon later.

pub mod client;
pub mod daemon;
pub mod db;
pub mod profile;
pub mod protocol;
pub mod spawn;

pub use client::{ensure_daemon, RuntimeClient, RuntimeClientError};
pub use profile::{profile_from_env, ProfilePaths};
pub use protocol::{RuntimeRequest, RuntimeResponse, PROTOCOL_VERSION};
