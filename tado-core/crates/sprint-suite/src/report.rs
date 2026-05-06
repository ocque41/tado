//! `SprintReport` — the JSON shape produced by `sprint-suite measure`
//! and consumed by `sprint-suite score` / `sprint-suite propose`.
//!
//! Lives at `.tado/eternal/runs/<id>/sprint-report.json`. Read by the
//! Cross-Run Browser (Swift) for the Sprint column tooltip and by
//! the architect when generating refactor proposals for
//! sprint_rules.txt.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::path::{Path, PathBuf};

/// One sprint's raw measurements. Matches the user-facing data
/// inputs from the original /loop optimizer prompt:
///   tickets_completed, points_completed, total_points_planned,
///   bugs_found_after_sprint, code_review_passes,
///   developer_satisfaction_score [1..5].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SprintData {
    pub tickets_completed: f64,
    pub points_completed: f64,
    pub total_points_planned: f64,
    pub bugs_found_after_sprint: f64,
    pub code_review_passes: f64,
    /// 1..5 inclusive; out-of-range values are clamped at scoring time.
    pub developer_satisfaction_score: f64,
}

impl SprintData {
    /// Velocity ratio (0..1+ — can exceed 1 when overdelivering).
    /// Returns 0 when `total_points_planned <= 0`.
    pub fn velocity_ratio(&self) -> f64 {
        if self.total_points_planned <= 0.0 {
            0.0
        } else {
            self.points_completed / self.total_points_planned
        }
    }

    /// Per-component contributions to the SprintSuccessScore.
    /// Returns the four addends in formula order so `explain` can
    /// pretty-print them.
    pub fn components(&self, weights: &Weights) -> [(String, f64); 4] {
        let velocity = (self.velocity_ratio() * 100.0) * weights.velocity;
        let reviews = self.code_review_passes * weights.code_review_passes;
        let bugs = self.bugs_found_after_sprint * weights.bugs_penalty;
        let sat = self.developer_satisfaction_score.clamp(1.0, 5.0) * weights.satisfaction;
        [
            ("velocity".into(), velocity),
            ("code_review_passes".into(), reviews),
            ("bugs_penalty".into(), -bugs),
            ("satisfaction".into(), sat),
        ]
    }
}

/// Weight overrides for the SprintSuccessScore formula. The defaults
/// match the original /loop optimizer prompt:
///   score = velocity * 100 + reviews * 2 - bugs * 10 + sat * 5
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Weights {
    pub velocity: f64,
    pub code_review_passes: f64,
    pub bugs_penalty: f64,
    pub satisfaction: f64,
}

impl Default for Weights {
    fn default() -> Self {
        Weights {
            velocity: 1.0,
            code_review_passes: 2.0,
            bugs_penalty: 10.0,
            satisfaction: 5.0,
        }
    }
}

/// Full per-run measurement output. One report = one APPLY+EVAL
/// cycle of the Eternal sprint loop.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SprintReport {
    pub schema_version: u32,
    pub captured_at: DateTime<Utc>,
    pub project_root: String,
    /// The `SprintData` row that was scored. Stored verbatim so future
    /// `explain` runs can re-render the breakdown without the source
    /// JSON.
    pub data: SprintData,
    /// Weights used at score time (after merging user overrides over
    /// `Weights::default()`).
    pub weights: Weights,
    /// Composite SprintSuccessScore — the value the formula produced.
    /// Capped to `[-200, 500]` to stop a single junk row from
    /// dominating the running ratchet.
    pub composite: f64,
    /// One human-readable line per component explaining what was
    /// actually measured (e.g. "velocity: 94.0 = (47/50) * 100 *
    /// 1.0").
    pub notes: Vec<String>,
    /// Path to `sprint_rules.txt` at measurement time. The hash is
    /// stored for future propose rounds so the gate can tell when
    /// the rules file changed between iterations.
    pub rules_file_hash: Option<String>,
}

#[derive(Debug)]
pub enum ReportError {
    Io { path: PathBuf, source: std::io::Error },
    Json(serde_json::Error),
    /// `sprint-data.json` was missing or empty. The gate treats this
    /// as `SCORE: NO-DATA-DETECTED` — a free pass on the very first
    /// run before the architect has dropped any sprint rows in.
    NoData(PathBuf),
}

impl fmt::Display for ReportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReportError::Io { path, source } => {
                write!(f, "io error reading/writing report at {path:?}: {source}")
            }
            ReportError::Json(e) => write!(f, "json (de)serialization failed: {e}"),
            ReportError::NoData(p) => write!(f, "no sprint data at {p:?}"),
        }
    }
}

impl std::error::Error for ReportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ReportError::Io { source, .. } => Some(source),
            ReportError::Json(e) => Some(e),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for ReportError {
    fn from(value: serde_json::Error) -> Self {
        ReportError::Json(value)
    }
}

pub fn read_report(path: &Path) -> Result<SprintReport, ReportError> {
    let bytes = std::fs::read(path).map_err(|e| ReportError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub fn write_report(path: &Path, report: &SprintReport) -> Result<(), ReportError> {
    let json = serde_json::to_vec_pretty(report)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| ReportError::Io {
            path: parent.to_path_buf(),
            source: e,
        })?;
    }
    std::fs::write(path, json).map_err(|e| ReportError::Io {
        path: path.to_path_buf(),
        source: e,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn velocity_ratio_handles_zero_planned() {
        let data = SprintData {
            tickets_completed: 0.0,
            points_completed: 0.0,
            total_points_planned: 0.0,
            bugs_found_after_sprint: 0.0,
            code_review_passes: 0.0,
            developer_satisfaction_score: 3.0,
        };
        assert_eq!(data.velocity_ratio(), 0.0);
    }

    #[test]
    fn components_match_original_formula() {
        // From the original prompt:
        //   score = (47/50)*100 + 12*2 - 1*10 + 4*5 = 94 + 24 - 10 + 20 = 128
        let data = SprintData {
            tickets_completed: 10.0,
            points_completed: 47.0,
            total_points_planned: 50.0,
            bugs_found_after_sprint: 1.0,
            code_review_passes: 12.0,
            developer_satisfaction_score: 4.0,
        };
        let weights = Weights::default();
        let parts = data.components(&weights);
        let total: f64 = parts.iter().map(|(_, v)| v).sum();
        assert!((total - 128.0).abs() < 0.01, "got {total}");
    }

    #[test]
    fn satisfaction_clamps_to_range() {
        let data = SprintData {
            tickets_completed: 0.0,
            points_completed: 0.0,
            total_points_planned: 1.0,
            bugs_found_after_sprint: 0.0,
            code_review_passes: 0.0,
            developer_satisfaction_score: 99.0,
        };
        let parts = data.components(&Weights::default());
        let sat = parts.iter().find(|(n, _)| n == "satisfaction").unwrap().1;
        assert_eq!(sat, 25.0, "satisfaction must clamp to 5*5=25");
    }
}
