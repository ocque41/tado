//! `sprint-suite` — measurable sprint-methodology evaluation for
//! Tado's Eternal Sprint step.
//!
//! The library face of the suite. The CLI in `bin/main.rs` composes
//! these primitives into the `detect | measure | score | propose |
//! baseline | explain` subcommands invoked by
//! `.tado/eternal/hooks/sprint-gate.sh`.
//!
//! Three modules:
//!
//! - **report** (`SprintReport`) — the JSON shape produced by
//!   `sprint-suite measure` and consumed by `sprint-suite score`.
//!   One report = one APPLY+EVAL cycle. Carries the SprintSuccessScore
//!   plus per-component breakdowns + a `notes` map for the hot-metric
//!   identifier on regression.
//!
//! - **scoring** — the additive `SprintSuccessScore` formula plus the
//!   per-component minimum guard. Identical contract shape to
//!   perf-suite's `ScoreVerdict::{Pass, Regression, BaselineInit}`,
//!   different prefix (`SCORE:` instead of `PERF:`).
//!
//! - **baseline** — per-project all-time-best ratchet, written
//!   atomically through `tado-settings::write_json`. Bounded
//!   ring-buffered history (last 50 entries) so file size stays
//!   small over long Eternal runs.
//!
//! The "methodology under optimization" is `sprint_rules.txt` in the
//! project root. The architect generates an initial version; the
//! worker edits ONE rule per iteration, runs the gate, and either
//! commits (if SCORE > baseline) or reverts.

pub mod baseline;
pub mod report;
pub mod scoring;

pub use baseline::{init_from, machine_class, machine_drift, read_baseline, update_with, write_baseline, Baseline, BaselineError, BaselineHistoryEntry};
pub use report::{SprintData, SprintReport, ReportError, Weights};
pub use scoring::{score, ScoreError, ScoreVerdict, DEFAULT_REGRESSION_FLOOR, PER_COMPONENT_MIN_GUARD};
