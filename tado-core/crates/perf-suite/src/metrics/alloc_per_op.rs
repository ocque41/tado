//! Heap allocations per logical operation.
//!
//! A *count*, not a duration. Counts are device-independent.
//!
//! Per-stack measurement:
//! - Rust: `dhat::HeapStats::new()` around the bench body
//! - Swift: Instruments `xctrace` Allocations template
//! - Node: `--prof` for V8 then parse the heap-allocation lines
//! - Python: `tracemalloc.start()` / `take_snapshot()`
//! - Go: `go test -bench -memprofile` + `go tool pprof -alloc_objects`

use super::{Direction, MetricSample};

pub const NAME: &str = "alloc_per_op";
pub const WEIGHT: f64 = 0.12;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "allocations/op";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
