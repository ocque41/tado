//! Composite scoring + per-component minimum guard for SprintSuccessScore.
//!
//! Inputs: a `SprintReport` from `sprint-suite measure` and a
//! `Baseline` file (`.tado/sprint-baselines/<project>.json`).
//!
//! Output: `ScoreVerdict::{Pass, Regression, BaselineInit}` — the
//! same enum shape perf-suite uses, with a different one-line stdout
//! prefix (`SCORE:` not `PERF:`).
//!
//! Algorithm:
//!
//! 1. Compute the composite via the formula:
//!      `score = velocity*100 + reviews*2 - bugs*10 + sat*5`
//!    (weights overridable via `Weights`).
//! 2. Cap at `[-200, 500]` to stop a single junk row from dominating
//!    the ratchet.
//! 3. Compare to `baseline.composite`. If `composite >=
//!    baseline.composite - DEFAULT_REGRESSION_FLOOR`, PASS.
//! 4. Per-component minimum guard:
//!    - `code_review_passes` must be `>=` baseline's value (else
//!      regression with hot_metric = "code_review_passes").
//!    - `bugs_found_after_sprint` must be `<=` baseline's (else
//!      regression with hot_metric = "bugs_found_after_sprint").
//!
//! When no baseline exists yet, returns `BaselineInit { composite }`
//! and the bash gate calls `baseline init`.

use crate::baseline::Baseline;
use crate::report::SprintReport;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Floor below which composite drops are treated as measurement
/// noise rather than regressions. 0.5 score points — small enough
/// that a real regression is caught, big enough that a single
/// satisfaction-survey wobble doesn't trip the gate.
pub const DEFAULT_REGRESSION_FLOOR: f64 = 0.5;

/// Per-sprint score is clamped to this range before any comparison.
/// `[-200, 500]` keeps any junk row (e.g. negative ticket count from
/// a malformed import) from poisoning the running ratchet.
pub const PER_COMPONENT_MIN_GUARD: (f64, f64) = (-200.0, 500.0);

#[derive(Debug)]
pub enum ScoreError {
    /// The composite came back NaN — every formula path should
    /// produce a finite number, so this is a hard programming error.
    NotFinite(f64),
}

impl fmt::Display for ScoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ScoreError::NotFinite(v) => write!(f, "non-finite composite score: {v}"),
        }
    }
}

impl std::error::Error for ScoreError {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ScoreVerdict {
    Pass {
        composite: f64,
    },
    Regression {
        composite: f64,
        delta: f64,
        hot_metric: String,
    },
    BaselineInit {
        composite: f64,
    },
}

impl ScoreVerdict {
    /// One-line stdout shape consumed by sprint-gate.sh. Prefix is
    /// `SCORE:` (not `PERF:`) so a worker grepping the transcript can
    /// disambiguate the two gates when both are wired into a project.
    pub fn one_line(&self) -> String {
        match self {
            ScoreVerdict::Pass { composite } => {
                format!("SCORE: PASS composite={composite:.3}")
            }
            ScoreVerdict::Regression {
                composite,
                delta,
                hot_metric,
            } => format!(
                "SCORE: REGRESSION delta={delta:.3} hot={hot_metric} composite={composite:.3}",
            ),
            ScoreVerdict::BaselineInit { composite } => {
                format!("SCORE: BASELINE-INIT composite={composite:.3}")
            }
        }
    }

    pub fn composite(&self) -> f64 {
        match self {
            ScoreVerdict::Pass { composite }
            | ScoreVerdict::Regression { composite, .. }
            | ScoreVerdict::BaselineInit { composite } => *composite,
        }
    }
}

pub fn score(report: &SprintReport, baseline: Option<&Baseline>) -> Result<ScoreVerdict, ScoreError> {
    let raw = report.composite;
    if !raw.is_finite() {
        return Err(ScoreError::NotFinite(raw));
    }
    let clamped = raw.clamp(PER_COMPONENT_MIN_GUARD.0, PER_COMPONENT_MIN_GUARD.1);

    let Some(baseline) = baseline else {
        return Ok(ScoreVerdict::BaselineInit { composite: clamped });
    };

    // Per-component guard: bugs_found_after_sprint can't go up,
    // code_review_passes can't go down.
    if let Some(bl_bugs) = baseline.components.get("bugs_found_after_sprint") {
        if report.data.bugs_found_after_sprint > *bl_bugs + DEFAULT_REGRESSION_FLOOR {
            return Ok(ScoreVerdict::Regression {
                composite: clamped,
                delta: report.data.bugs_found_after_sprint - bl_bugs,
                hot_metric: "bugs_found_after_sprint".into(),
            });
        }
    }
    if let Some(bl_reviews) = baseline.components.get("code_review_passes") {
        if report.data.code_review_passes + DEFAULT_REGRESSION_FLOOR < *bl_reviews {
            return Ok(ScoreVerdict::Regression {
                composite: clamped,
                delta: bl_reviews - report.data.code_review_passes,
                hot_metric: "code_review_passes".into(),
            });
        }
    }

    let delta = baseline.composite - clamped;
    if delta > DEFAULT_REGRESSION_FLOOR {
        return Ok(ScoreVerdict::Regression {
            composite: clamped,
            delta,
            hot_metric: "composite".into(),
        });
    }

    Ok(ScoreVerdict::Pass { composite: clamped })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::baseline::Baseline;
    use crate::report::{SprintData, Weights};
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn report(composite: f64, bugs: f64, reviews: f64) -> SprintReport {
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
            composite,
            notes: vec![],
            rules_file_hash: None,
        }
    }

    fn baseline(composite: f64, bugs: f64, reviews: f64) -> Baseline {
        let mut components = BTreeMap::new();
        components.insert("bugs_found_after_sprint".into(), bugs);
        components.insert("code_review_passes".into(), reviews);
        Baseline {
            schema_version: 1,
            updated_at: Utc::now(),
            composite,
            components,
            machine_class: None,
            history: vec![],
        }
    }

    #[test]
    fn first_run_is_baseline_init() {
        let r = report(120.0, 1.0, 12.0);
        let v = score(&r, None).unwrap();
        assert!(matches!(v, ScoreVerdict::BaselineInit { .. }));
    }

    #[test]
    fn improvement_passes() {
        let r = report(140.0, 1.0, 14.0);
        let b = baseline(120.0, 2.0, 12.0);
        let v = score(&r, Some(&b)).unwrap();
        assert!(matches!(v, ScoreVerdict::Pass { .. }));
    }

    #[test]
    fn composite_drop_regresses() {
        let r = report(100.0, 1.0, 12.0);
        let b = baseline(120.0, 1.0, 12.0);
        let v = score(&r, Some(&b)).unwrap();
        assert!(matches!(v, ScoreVerdict::Regression { hot_metric, .. } if hot_metric == "composite"));
    }

    #[test]
    fn bug_spike_regresses_even_when_composite_higher() {
        // Score went up because we shipped more points, but bugs
        // also doubled — guard should regress.
        let r = report(140.0, 5.0, 12.0);
        let b = baseline(120.0, 2.0, 12.0);
        let v = score(&r, Some(&b)).unwrap();
        assert!(matches!(v, ScoreVerdict::Regression { hot_metric, .. } if hot_metric == "bugs_found_after_sprint"));
    }

    #[test]
    fn review_count_drop_regresses() {
        let r = report(140.0, 1.0, 8.0);
        let b = baseline(120.0, 1.0, 12.0);
        let v = score(&r, Some(&b)).unwrap();
        assert!(matches!(v, ScoreVerdict::Regression { hot_metric, .. } if hot_metric == "code_review_passes"));
    }

    #[test]
    fn floor_absorbs_noise() {
        let r = report(119.7, 1.0, 12.0);
        let b = baseline(120.0, 1.0, 12.0);
        let v = score(&r, Some(&b)).unwrap();
        assert!(matches!(v, ScoreVerdict::Pass { .. }));
    }
}
