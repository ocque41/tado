//! Cold-start operation count: operations executed from process spawn
//! to "ready" signal.
//!
//! Counted via tracing, not timed. The "ready" signal is project-
//! defined: a stdout sentinel ("ready", "listening", "started"), an
//! HTTP /healthz returning 200, or a TCP port becoming accepting.
//! Adapters fall back to the project's `bench/cold-start.sh` script
//! if no signal is configured.
//!
//! Per-stack measurement:
//! - All stacks: spawn the project's main binary / entry script,
//!   sample tracing spans until ready, count distinct ops.
//! - The adapter sets `value = 0.0` and a notes line if no entry
//!   script is detectable; scoring treats this as neutral.

use super::{Direction, MetricSample};

pub const NAME: &str = "cold_start_ops";
pub const WEIGHT: f64 = 0.13;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "ops";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
