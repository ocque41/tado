//! tado-core — terminal core for the Tado macOS app.
//!
//! Architecture (Phase 1):
//! - `pty` spawns a child process under a PTY via `portable-pty`
//! - `grid` is the cell-by-cell terminal state (width × height of `Cell`s)
//! - `performer` implements `vte::Perform` to mutate the grid from PTY bytes
//! - `session` ties them together: reader thread -> performer -> grid -> snapshot
//! - `ffi` exposes a plain C ABI consumed by Swift
//!
//! Swift calls `tado_session_spawn`, gets an opaque handle, polls
//! `tado_session_snapshot` each frame to get dirty cells + cursor, and writes
//! keyboard bytes back via `tado_session_write`.

pub mod composition;
pub mod ffi;
pub mod grid;
pub mod performer;
pub mod pty;
pub mod session;

pub use session::Session;
