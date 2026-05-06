//! Per-project baseline file at
//! `<project-root>/.tado/sprint-baselines/<safe-project-name>.json`.
//!
//! Stores the all-time-best SprintSuccessScore + per-component guard
//! values (best bugs, best code_review_passes). Updated ONLY on
//! PASS via `tado_settings::write_json` (atomic store: temp + fsync
//! + rename). Never updated on REGRESSION — that's the ratchet.
//!
//! `history` is bounded to the last 50 entries by the writer
//! (caller truncates before write) so the file size stays bounded
//! across long Eternal runs.

use crate::report::SprintReport;
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
    /// Per-component values: `bugs_found_after_sprint` (lowest seen),
    /// `code_review_passes` (highest seen). The score guard reads
    /// these directly — composite alone can mask a regression in one
    /// component if another improved.
    pub components: BTreeMap<String, f64>,
    /// Recorded once at first write. Future writes that detect a
    /// mismatch refuse to update — protects shared-team baselines from
    /// silently drifting when the project moves between machines.
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
    // `read_json` already returns `Ok(None)` for a missing file and
    // `AtomicError::Empty` for an empty one — fold both to None so
    // the gate's first-run path doesn't have to distinguish.
    match tado_settings::read_json::<Baseline>(path) {
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
pub fn init_from(report: &SprintReport, composite: f64) -> Baseline {
    let mut components = BTreeMap::new();
    components.insert(
        "bugs_found_after_sprint".into(),
        report.data.bugs_found_after_sprint,
    );
    components.insert(
        "code_review_passes".into(),
        report.data.code_review_passes,
    );
    components.insert("velocity_ratio".into(), report.data.velocity_ratio());
    components.insert(
        "developer_satisfaction_score".into(),
        report.data.developer_satisfaction_score,
    );
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
/// safety refusal via `TADO_SPRINT_ALLOW_DRIFT=1`.
pub fn machine_drift(baseline: &Baseline) -> bool {
    let current = machine_class();
    matches!(&baseline.machine_class, Some(stored) if stored != &current)
}

/// Update an existing baseline with the latest successful run.
/// Per-component values move to whichever side is "better" for that
/// metric's direction (bugs lower-is-better, others higher-is-better).
/// Composite advances to the new value (only called when score
/// passes).
pub fn update_with(baseline: &Baseline, report: &SprintReport, composite: f64) -> Baseline {
    let mut updated = baseline.clone();
    updated.updated_at = Utc::now();
    updated.composite = composite;

    // bugs: keep the lowest ever seen
    let prev_bugs = updated
        .components
        .get("bugs_found_after_sprint")
        .copied()
        .unwrap_or(f64::INFINITY);
    if report.data.bugs_found_after_sprint < prev_bugs {
        updated
            .components
            .insert("bugs_found_after_sprint".into(), report.data.bugs_found_after_sprint);
    }

    // code_review_passes / velocity_ratio / satisfaction: keep the
    // highest ever seen
    for (key, val) in [
        ("code_review_passes", report.data.code_review_passes),
        ("velocity_ratio", report.data.velocity_ratio()),
        (
            "developer_satisfaction_score",
            report.data.developer_satisfaction_score,
        ),
    ] {
        let prev = updated.components.get(key).copied().unwrap_or(f64::NEG_INFINITY);
        if val > prev {
            updated.components.insert(key.into(), val);
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

/// Best-effort machine class string — same shape perf-suite uses so
/// users see a familiar value in both baselines.
pub fn machine_class() -> String {
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;
    match (arch, os) {
        ("aarch64", "macos") => "apple-silicon-macos".into(),
        ("x86_64", "macos") => "intel-macos".into(),
        (_, "linux") => "linux".into(),
        (_, "windows") => "windows".into(),
        (a, o) => format!("{a}-{o}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::{SprintData, Weights};

    fn fixture_report(bugs: f64, reviews: f64) -> SprintReport {
        SprintReport {
            schema_version: 1,
            captured_at: Utc::now(),
            project_root: "/tmp/test".into(),
            data: SprintData {
                tickets_completed: 10.0,
                points_completed: 47.0,
                total_points_planned: 50.0,
                bugs_found_after_sprint: bugs,
                code_review_passes: reviews,
                developer_satisfaction_score: 4.0,
            },
            weights: Weights::default(),
            composite: 120.0,
            notes: vec![],
            rules_file_hash: None,
        }
    }

    #[test]
    fn init_captures_components() {
        let r = fixture_report(2.0, 12.0);
        let b = init_from(&r, 120.0);
        assert_eq!(b.components.get("bugs_found_after_sprint"), Some(&2.0));
        assert_eq!(b.components.get("code_review_passes"), Some(&12.0));
        assert_eq!(b.history.len(), 1);
    }

    #[test]
    fn update_keeps_lowest_bugs() {
        let initial = init_from(&fixture_report(2.0, 12.0), 120.0);
        let next = update_with(&initial, &fixture_report(5.0, 14.0), 130.0);
        // bugs went UP → baseline keeps the lower 2.0
        assert_eq!(next.components.get("bugs_found_after_sprint"), Some(&2.0));
        // reviews went UP → baseline takes the higher 14.0
        assert_eq!(next.components.get("code_review_passes"), Some(&14.0));
        assert_eq!(next.composite, 130.0);
        assert_eq!(next.history.len(), 2);
    }

    #[test]
    fn history_caps_at_50() {
        let mut b = init_from(&fixture_report(2.0, 12.0), 100.0);
        for i in 0..60 {
            b = update_with(&b, &fixture_report(2.0, 12.0), 100.0 + i as f64);
        }
        assert!(b.history.len() <= 50);
    }
}
