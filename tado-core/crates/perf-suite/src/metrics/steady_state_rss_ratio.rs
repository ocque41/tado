//! Steady-state RSS ratio: `RSS_after_N_ops / RSS_at_op_1` after a
//! synthetic 1000-op workload. Target ≤ 1.10× (10% growth tolerated;
//! anything more suggests an unbounded cache, leak, or growing buffer
//! per operation).
//!
//! A *ratio* between two same-machine measurements is
//! device-independent. Memory growth that's harmless on 32 GB
//! machines is a cliff on 8 GB machines, but the ratio catches it
//! either way.
//!
//! Per-stack measurement:
//! - All stacks: spawn process, run 1 op, sample `ps -o rss= -p $pid`
//!   (KB), run 1000 more ops, sample again, return ratio.
//! - Adapter constraints: 1000 ops shouldn't be too few (noise) or
//!   too many (test takes minutes); adapters can override via
//!   `MeasurementContext::per_metric_budget_secs`.

use super::{Direction, MetricSample};

pub const NAME: &str = "steady_state_rss_ratio";
pub const WEIGHT: f64 = 0.15;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "ratio";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
