pub mod automation;
pub mod code;
pub mod config;
pub mod context;
pub mod db;
pub mod enrichment;
pub mod error;
pub mod fs_guard;
pub mod migrations;
pub mod model;
pub mod notes;
pub mod recipes;
pub mod rpc;
pub mod service;
// v0.18 zombie-process sweeper. Lives at the top level of bt-core
// (rather than under `service`) because it has no dependence on the
// vault, the daemon, or any RPC machinery — it's a pure
// process-listing-and-signaling routine that the FFI exposes
// directly. See `src/zombie.rs` for the self-protection contract.
pub mod zombie;

pub use error::BtError;
pub use model::Actor;
pub use service::{CoreService, WriteOperation};

