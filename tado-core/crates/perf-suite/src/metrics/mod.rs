//! The eight curated performance metrics.
//!
//! Each metric is a sub-module that implements the `Metric` trait.
//! Adapters call into these modules to produce raw `MetricSample`s,
//! which then feed `scoring::score` to produce a composite.
//!
//! Weights (sum to 1.0):
//!
//! | name | weight | direction |
//! |---|---|---|
//! | algo_complexity         | 0.18 | LowerIsBetter (slope) |
//! | alloc_per_op            | 0.12 | LowerIsBetter (count) |
//! | critical_path_ops       | 0.12 | LowerIsBetter (count) |
//! | io_syscalls_per_op      | 0.10 | LowerIsBetter (count) |
//! | db_query_cost           | 0.10 | LowerIsBetter (cost) |
//! | xproc_roundtrips        | 0.10 | LowerIsBetter (count) |
//! | cold_start_ops          | 0.13 | LowerIsBetter (count) |
//! | steady_state_rss_ratio  | 0.15 | LowerIsBetter (ratio) |

pub mod algo_complexity;
pub mod alloc_per_op;
pub mod cold_start_ops;
pub mod critical_path_ops;
pub mod db_query_cost;
pub mod io_syscalls_per_op;
pub mod steady_state_rss_ratio;
pub mod xproc_roundtrips;

use serde::{Deserialize, Serialize};

/// Whether a higher raw value is good or bad. Composite normalization
/// flips the ratio for `LowerIsBetter` so all normalized scores read
/// the same way (>1.0 = improvement).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Direction {
    /// Counts, slopes, ratios, latencies — smaller is better.
    LowerIsBetter,
    /// Throughput, ops/sec — larger is better.
    HigherIsBetter,
}

/// One raw measurement from one adapter for one metric.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricSample {
    /// The actual measurement (count, slope, ratio, etc.).
    pub value: f64,
    /// Human-readable unit string for the report and `explain`
    /// subcommand. Examples: "allocations/op", "slope", "ratio",
    /// "ops" (for cold-start), "syscalls/op".
    pub unit: String,
    pub direction: Direction,
    /// Which adapter (`rust`, `swift`, `node`, `python`, `go`,
    /// `polyglot`) produced the sample. Stored on the sample so a
    /// polyglot project's report breaks down per language without a
    /// separate field.
    pub adapter: String,
    /// Optional human-readable explanation (one short line).
    pub notes: Option<String>,
}

/// Trait every metric module exposes. Adapters know which metrics
/// they can measure and call the relevant module's `measure`.
pub trait Metric {
    fn name(&self) -> &'static str;
    fn weight(&self) -> f64;
    fn direction(&self) -> Direction;
}

/// The eight metrics, with their stable names and weights. Used by
/// scoring to (a) iterate the registry, (b) redistribute weight when
/// a metric is omitted from the report.
pub fn registry() -> Vec<(&'static str, f64, Direction)> {
    vec![
        ("algo_complexity", 0.18, Direction::LowerIsBetter),
        ("alloc_per_op", 0.12, Direction::LowerIsBetter),
        ("critical_path_ops", 0.12, Direction::LowerIsBetter),
        ("io_syscalls_per_op", 0.10, Direction::LowerIsBetter),
        ("db_query_cost", 0.10, Direction::LowerIsBetter),
        ("xproc_roundtrips", 0.10, Direction::LowerIsBetter),
        ("cold_start_ops", 0.13, Direction::LowerIsBetter),
        ("steady_state_rss_ratio", 0.15, Direction::LowerIsBetter),
    ]
}

/// Total weight of the registry. Should be 1.0 by construction; the
/// scoring layer asserts this on every run.
pub fn total_weight() -> f64 {
    registry().iter().map(|(_, w, _)| w).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_weights_sum_to_one() {
        let total: f64 = registry().iter().map(|(_, w, _)| w).sum();
        assert!((total - 1.0).abs() < 1e-9, "got total={total}");
    }

    #[test]
    fn registry_has_eight_metrics() {
        assert_eq!(registry().len(), 8);
    }

    #[test]
    fn registry_names_are_unique() {
        use std::collections::HashSet;
        let names: HashSet<_> = registry().iter().map(|(n, _, _)| *n).collect();
        assert_eq!(names.len(), 8);
    }
}
