//! Per-project baseline file at
//! `<project-root>/.tado/perf-baselines/<safe-project-name>.json`.
//!
//! Stores the all-time-best composite + per-component scores. Updated
//! ONLY on PASS via `tado_settings::write_json` (atomic store: temp +
//! fsync + rename). Never updated on REGRESSION — that's the ratchet.
//!
//! `history` is bounded to the last 50 entries by the writer (caller
//! truncates before write) so the file size stays bounded across long
//! Eternal runs.

use crate::report::PerfReport;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

#[derive(Debug)]
pub enum BaselineError {
    Settings(tado_settings::AtomicError),
}

impl fmt::Display for BaselineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BaselineError::Settings(e) => write!(f, "atomic store error: {e}"),
        }
    }
}

impl std::error::Error for BaselineError {}

impl From<tado_settings::AtomicError> for BaselineError {
    fn from(value: tado_settings::AtomicError) -> Self {
        BaselineError::Settings(value)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Baseline {
    pub schema_version: u32,
    pub updated_at: DateTime<Utc>,
    pub composite: f64,
    pub components: BTreeMap<String, f64>,
    /// Recorded once at first write. Future writes that detect a
    /// mismatch refuse to update and emit a `perfMachineDrift` warning
    /// — protects shared-team baselines from silently drifting when
    /// the project is opened on a new device.
    pub machine_class: Option<String>,
    /// Bounded ring buffer (last 50 entries). Each entry is one
    /// successful PASS — useful for trend display in the Cross-Run
    /// Browser.
    pub history: Vec<BaselineHistoryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BaselineHistoryEntry {
    pub captured_at: DateTime<Utc>,
    pub composite: f64,
}

const HISTORY_CAP: usize = 50;

pub fn read_baseline(path: &Path) -> Result<Option<Baseline>, BaselineError> {
    // Treat an empty file the same as a missing one. The gate's
    // workflow may pre-touch the path (e.g. via `mktemp`) before the
    // first `baseline init`, and an empty file is semantically "no
    // baseline yet" — not a hard failure.
    match tado_settings::read_json(path) {
        Ok(v) => Ok(v),
        Err(tado_settings::AtomicError::Empty { .. }) => Ok(None),
        Err(e) => Err(BaselineError::Settings(e)),
    }
}

pub fn write_baseline(path: &Path, baseline: &Baseline) -> Result<(), BaselineError> {
    tado_settings::write_json(path, baseline)?;
    Ok(())
}

/// Build a brand-new `Baseline` from a successful first-run report.
pub fn init_from(report: &PerfReport, composite: f64) -> Baseline {
    let mut components = BTreeMap::new();
    for (name, sample) in &report.samples {
        if sample.value > 0.0 {
            components.insert(name.clone(), sample.value);
        }
    }
    Baseline {
        schema_version: 1,
        updated_at: Utc::now(),
        composite,
        components,
        machine_class: Some(machine_class()),
        history: vec![BaselineHistoryEntry {
            captured_at: Utc::now(),
            composite,
        }],
    }
}

/// True when the baseline was recorded on a different machine class
/// than the one we're running on now. Operators can override the
/// safety refusal via `TADO_PERF_ALLOW_DRIFT=1`.
pub fn machine_drift(baseline: &Baseline) -> bool {
    let current = machine_class();
    matches!(&baseline.machine_class, Some(stored) if stored != &current)
}

/// Update an existing baseline with the latest successful run.
/// Per-component values move to whichever side is "better" for that
/// metric's direction. Composite advances to the new value (since
/// it's only called when score >= baseline).
pub fn update_with(baseline: &Baseline, report: &PerfReport, composite: f64) -> Baseline {
    use crate::metrics::Direction;
    let mut updated = baseline.clone();
    updated.updated_at = Utc::now();
    updated.composite = composite;
    for (name, sample) in &report.samples {
        if sample.value <= 0.0 {
            continue;
        }
        let new_better = match (updated.components.get(name), sample.direction) {
            (Some(prev), Direction::LowerIsBetter) => sample.value < *prev,
            (Some(prev), Direction::HigherIsBetter) => sample.value > *prev,
            (None, _) => true,
        };
        if new_better {
            updated.components.insert(name.clone(), sample.value);
        }
    }
    updated.history.push(BaselineHistoryEntry {
        captured_at: Utc::now(),
        composite,
    });
    if updated.history.len() > HISTORY_CAP {
        let drop = updated.history.len() - HISTORY_CAP;
        updated.history.drain(..drop);
    }
    updated
}

pub fn machine_class() -> String {
    #[cfg(target_os = "macos")]
    {
        if cfg!(target_arch = "aarch64") {
            return "apple-silicon-macos".into();
        }
        return "intel-macos".into();
    }
    #[cfg(target_os = "linux")]
    {
        return "linux".into();
    }
    #[cfg(target_os = "windows")]
    {
        return "windows".into();
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        "unknown".into()
    }
}
