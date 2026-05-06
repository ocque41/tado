//! `perf-suite` — measurable performance evaluation for Tado's Eternal
//! Performance step.
//!
//! This is the library face of the suite. The CLI in `bin/main.rs`
//! composes these primitives into the `detect | measure | score |
//! propose | baseline | explain` subcommands invoked by
//! `.tado/eternal/hooks/perf-gate.sh`.
//!
//! Three layers, top to bottom:
//!
//! - **Adapters** (`adapters::`) — stack-specific knowledge. Each
//!   adapter knows how to detect its stack from project root files
//!   (`Cargo.toml`, `Package.swift`, `package.json`, `pyproject.toml`,
//!   `go.mod`) and how to invoke the language-native tools that feed
//!   each metric (e.g. `cargo bench` + `dhat` for Rust, XCTest
//!   `.measure` for Swift, `tinybench` + `clinic` for Node).
//!
//! - **Metrics** (`metrics::`) — the eight curated dimensions that
//!   make up the composite. Each metric has a stable `name`, a default
//!   weight, and a `direction` (`LowerIsBetter` or `HigherIsBetter`).
//!   Adapters provide raw measurements; the suite normalizes them
//!   against the baseline.
//!
//! - **Scoring + baseline + proposals** — the orchestration that
//!   turns adapter+metric output into the single composite score the
//!   gate either passes or fails. The baseline file
//!   (`.tado/perf-baselines/<project>.json`) is the all-time best, so
//!   the ratchet is monotonic.

pub mod adapters;
pub mod baseline;
pub mod metrics;
pub mod proposal;
pub mod report;
pub mod runtime;
pub mod scoring;

pub use adapters::{detect_adapter, Adapter, AdapterError, Stack};
pub use baseline::{read_baseline, write_baseline, Baseline, BaselineError};
pub use metrics::{Direction, Metric, MetricSample};
pub use proposal::{generate_proposals, Proposal};
pub use report::{ComponentScore, PerfReport, ReportError};
pub use scoring::{score, ScoreError, ScoreVerdict};

use std::path::PathBuf;

/// One full measurement context — passed into adapters so each can
/// produce its share of metric samples for the eight dimensions.
///
/// Keeping this small and `Clone`-able means adapters can fan out
/// per-metric with no bookkeeping.
#[derive(Debug, Clone)]
pub struct MeasurementContext {
    /// Absolute path to the project root the worker is editing.
    pub project_root: PathBuf,
    /// Absolute path to the per-run dir under `.tado/eternal/runs/<id>/`.
    /// Used as scratch + report destination.
    pub run_dir: PathBuf,
    /// Adapter-detected stack. Adapters self-report; tests can pin.
    pub stack: Stack,
    /// Optional override: cap each metric measurement at this many
    /// seconds. `None` lets the adapter choose. Mostly useful in CI
    /// to bound total runtime.
    pub per_metric_budget_secs: Option<u64>,
}
