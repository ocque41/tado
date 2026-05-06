//! Cross-process / cross-language round-trip count per logical
//! operation: FFI hops, IPC messages, RPC calls, network requests
//! made in dev mode.
//!
//! A *count*. Cross-boundary calls have fixed marshaling overhead
//! that's difficult to amortize, so reducing the count is one of the
//! most reliable performance wins. This metric also captures
//! cross-process serialization waits (e.g. waiting for a subprocess'
//! reply).
//!
//! Per-stack measurement:
//! - Rust: count `extern "C"` boundary crossings via `tracing` spans
//!   tagged `boundary = "ffi"`.
//! - Swift: same, via `OSSignposter` spans tagged with the boundary.
//! - Node: hook `worker_threads.MessagePort` events and outbound
//!   `net.Socket` writes.
//! - Python: count `ctypes` / `cffi` calls + `multiprocessing` pipe
//!   messages.
//! - Go: count `cgo` calls + outbound `net` package operations.

use super::{Direction, MetricSample};

pub const NAME: &str = "xproc_roundtrips";
pub const WEIGHT: f64 = 0.10;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "roundtrips/op";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
