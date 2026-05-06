//! `PerfReport` — the JSON shape produced by `perf-suite measure` and
//! consumed by `perf-suite score` / `perf-suite propose`.
//!
//! Lives at `.tado/eternal/runs/<id>/perf-report.json`. Read by the
//! Cross-Run Browser (Swift) for the Perf column tooltip and by the
//! `eternal-performance-evaluator` agent when generating refactor
//! proposals.

use crate::adapters::Stack;
use crate::metrics::{Direction, MetricSample};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum ReportError {
    Io { path: PathBuf, source: std::io::Error },
    Json(serde_json::Error),
}

impl fmt::Display for ReportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReportError::Io { path, source } => {
                write!(f, "io error reading/writing report at {path:?}: {source}")
            }
            ReportError::Json(e) => write!(f, "json (de)serialization failed: {e}"),
        }
    }
}

impl std::error::Error for ReportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ReportError::Io { source, .. } => Some(source),
            ReportError::Json(e) => Some(e),
        }
    }
}

impl From<serde_json::Error> for ReportError {
    fn from(value: serde_json::Error) -> Self {
        ReportError::Json(value)
    }
}

/// Full per-run measurement output. Capped at the eight known metric
/// names but `samples` is keyed by string so a future ninth dimension
/// rides for free.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerfReport {
    pub schema_version: u32,
    pub captured_at: DateTime<Utc>,
    pub project_root: String,
    pub stack: Stack,
    /// Map of metric_name -> raw sample. Adapters that have no signal
    /// for a dimension omit it; `score` treats omitted dimensions as
    /// neutral (1.0) and proportionally redistributes their weight.
    pub samples: BTreeMap<String, MetricSample>,
    /// Adapter-supplied notes — usually one human-readable line per
    /// metric explaining what was actually measured (e.g. "ran cargo
    /// bench grid_bench, measured median of 30 iterations").
    pub notes: BTreeMap<String, String>,
    /// True only if the adapter's correctness gate (tests) passed
    /// before measurement. False = the gate refused to score and the
    /// report is informational only.
    pub correctness_ok: bool,
    /// If `correctness_ok` is false, what failed.
    pub correctness_failure: Option<String>,
}

impl PerfReport {
    /// Per-component normalized score relative to a baseline value.
    /// Returns 1.0 if either side is `None` or zero (neutral).
    pub fn normalized_component(
        &self,
        name: &str,
        baseline_value: Option<f64>,
    ) -> Option<ComponentScore> {
        let sample = self.samples.get(name)?;
        let baseline = baseline_value?;
        if baseline == 0.0 || sample.value == 0.0 {
            return Some(ComponentScore {
                name: name.to_string(),
                normalized: 1.0,
                raw_value: sample.value,
                baseline_value: baseline,
                direction: sample.direction,
            });
        }
        let ratio = match sample.direction {
            Direction::LowerIsBetter => baseline / sample.value,
            Direction::HigherIsBetter => sample.value / baseline,
        };
        Some(ComponentScore {
            name: name.to_string(),
            normalized: ratio.clamp(0.0, 2.0),
            raw_value: sample.value,
            baseline_value: baseline,
            direction: sample.direction,
        })
    }

    pub fn write_to(&self, path: &Path) -> Result<(), ReportError> {
        let bytes = serde_json::to_vec_pretty(self)?;
        std::fs::write(path, bytes).map_err(|source| ReportError::Io {
            path: path.to_path_buf(),
            source,
        })
    }

    pub fn read_from(path: &Path) -> Result<Self, ReportError> {
        let bytes = std::fs::read(path).map_err(|source| ReportError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        Ok(serde_json::from_slice(&bytes)?)
    }
}

/// One component's normalized score against a baseline. `normalized`
/// is in `[0, 2]`; 1.0 means matches baseline, >1 = improvement,
/// <1 = regression.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComponentScore {
    pub name: String,
    pub normalized: f64,
    pub raw_value: f64,
    pub baseline_value: f64,
    pub direction: Direction,
}
