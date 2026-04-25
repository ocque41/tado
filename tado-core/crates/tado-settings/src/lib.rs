//! `tado-settings` — persisted configuration primitives for Tado.
//!
//! ## Status (T3)
//!
//! Three pieces land in this phase:
//!
//! - [`scope::Scope`] — the five-scope hierarchy mirroring Swift's
//!   `AppSettingsSync` / `ProjectSettingsSync` design. Highest
//!   precedence wins when two scopes carry the same key.
//! - [`atomic::read_json`] / [`atomic::write_json`] — the
//!   temp-file + fsync + rename discipline used by Swift's
//!   `AtomicStore` today. Single-writer correctness is the
//!   baseline; `flock`-style cross-process locking comes in a
//!   follow-up once the Swift side delegates into this crate at
//!   runtime.
//! - [`paths::SettingsPaths`] — canonical Application Support /
//!   per-project path derivation, including the fixed storage
//!   locator used when the user moves Tado's global store.
//!
//! ## What's deferred
//!
//! - Scope resolver / merger (takes a stack of `(Scope, Value)`
//!   and walks the hierarchy to produce the effective value for a
//!   key). Lands once Tado has real workloads calling in.
//! - Migration runner + backup tarball producer. Both are pure
//!   mechanical ports; they live separately because each has its
//!   own test surface.
//! - File watcher (DispatchSource in Swift, `notify` crate in
//!   Rust). Gets wired in at the same time the Swift shell
//!   subscribes to the Rust watcher callback.

pub mod atomic;
pub mod paths;
pub mod scope;

pub use atomic::{read_json, write_json, AtomicError};
pub use paths::{SettingsPaths, StorageLocationRecord};
pub use scope::Scope;
