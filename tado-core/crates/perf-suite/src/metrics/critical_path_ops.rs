//! Critical-path operation count: instructions / function calls /
//! branches executed serially on the hot path of the benchmark.
//!
//! Counted via instrumentation, not timed. Lock waits and async stalls
//! show up as serialized work, so this metric also captures contention
//! pressure indirectly.
//!
//! Per-stack measurement:
//! - Rust: `cargo-llvm-cov` + perf counters or `coz` profiler ops
//! - Swift: Instruments "System Trace" instructions-retired counter
//! - Node: `--prof` tick samples on the main thread
//! - Python: `cProfile` with cumulative call count
//! - Go: `go tool pprof -nodecount` on `cpuprofile`

use super::{Direction, MetricSample};

pub const NAME: &str = "critical_path_ops";
pub const WEIGHT: f64 = 0.12;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "ops/op";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
