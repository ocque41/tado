//! Composite scoring + per-component minimum guard.
//!
//! Inputs: a `PerfReport` from `perf-suite measure` and a `Baseline`
//! file (`.tado/perf-baselines/<project>.json`).
//!
//! Output: `ScoreVerdict::Pass { composite }` or
//! `ScoreVerdict::Regression { delta, hot_metric, composite }` or
//! `ScoreVerdict::BaselineInit { composite }`.
//!
//! Algorithm:
//!
//! 1. Walk the eight-metric registry. For each metric:
//!    - If both `report.samples[name]` and `baseline.components[name]`
//!      are present, normalize via direction-aware ratio (clamped
//!      `[0, 2]`).
//!    - If the metric is absent from the report (adapter has no
//!      signal), record `weight=0` for that metric and proportionally
//!      redistribute its registry weight to the present metrics.
//! 2. Composite = `Σ effective_weight_i × normalized_i`. Total
//!    normalized weight always sums to 1.0 by construction.
//! 3. Per-component minimum guard: if any present `normalized_i <
//!    0.85`, the verdict is REGRESSION even if composite >= baseline.
//! 4. Composite delta = `composite_baseline - composite_new`. If
//!    positive (regression) AND > `regression_floor` (default 0.005),
//!    REGRESSION. Otherwise PASS.

use crate::baseline::Baseline;
use crate::metrics::registry;
use crate::report::PerfReport;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Floor below which composite drops are treated as measurement
/// noise rather than regressions. 0.005 = 0.5% — small enough that a
/// real regression is caught, big enough that a +/-1 sample outlier
/// doesn't trip the gate.
pub const DEFAULT_REGRESSION_FLOOR: f64 = 0.005;

/// Per-component normalized score below which the gate fails even
/// when the composite is fine. Stops "improve A by 50%, regress B by
/// 50%" from masking a real degradation.
pub const PER_COMPONENT_MIN_GUARD: f64 = 0.85;

#[derive(Debug)]
pub enum ScoreError {
    /// The registry weights didn't sum to 1.0 — should be impossible
    /// in practice; treated as a hard programming error.
    BadWeights(f64),
}

impl fmt::Display for ScoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ScoreError::BadWeights(total) => write!(
                f,
                "metric registry weights do not sum to 1.0 (total={total})",
            ),
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
        per_component: Vec<(String, f64)>,
    },
    BaselineInit {
        composite: f64,
    },
}

impl ScoreVerdict {
    /// One-line stdout shape consumed by perf-gate.sh.
    pub fn one_line(&self) -> String {
        match self {
            ScoreVerdict::Pass { composite } => {
                format!("PERF: PASS composite={composite:.3}")
            }
            ScoreVerdict::Regression {
                composite,
                delta,
                hot_metric,
                ..
            } => format!(
                "PERF: REGRESSION delta={delta:.3} hot={hot_metric} composite={composite:.3}",
            ),
            ScoreVerdict::BaselineInit { composite } => {
                format!("PERF: BASELINE-INIT composite={composite:.3}")
            }
        }
    }
}

pub fn score(report: &PerfReport, baseline: Option<&Baseline>) -> Result<ScoreVerdict, ScoreError> {
    let registry = registry();
    let total_registry_weight: f64 = registry.iter().map(|(_, w, _)| w).sum();
    if (total_registry_weight - 1.0).abs() > 1e-6 {
        return Err(ScoreError::BadWeights(total_registry_weight));
    }

    // First pass: compute present metrics' raw weights and normalized
    // values. Anything where the report has no sample (or the adapter
    // returned a sentinel zero) is treated as absent.
    let mut present: Vec<(&str, f64, f64)> = Vec::new(); // (name, weight, normalized)
    let mut missing_weight = 0.0;

    for (name, weight, _direction) in &registry {
        let baseline_value = baseline.and_then(|b| b.components.get(*name).copied());
        match report.normalized_component(name, baseline_value) {
            Some(comp) if comp.raw_value > 0.0 || comp.baseline_value > 0.0 => {
                present.push((name, *weight, comp.normalized));
            }
            _ => missing_weight += weight,
        }
    }

    // No baseline yet → BASELINE-INIT regardless of values.
    if baseline.is_none() {
        let composite = if present.is_empty() {
            1.0
        } else {
            present.iter().map(|(_, w, n)| w * n).sum::<f64>()
                / present.iter().map(|(_, w, _)| w).sum::<f64>()
        };
        return Ok(ScoreVerdict::BaselineInit { composite });
    }

    // Redistribute missing weight proportionally across present metrics.
    if present.is_empty() {
        // No present metrics — nothing to compare. Treat as PASS at
        // composite=1.0 (neutral), so the gate doesn't false-fail
        // when adapters can't produce signal.
        return Ok(ScoreVerdict::Pass { composite: 1.0 });
    }
    let present_weight: f64 = present.iter().map(|(_, w, _)| w).sum();
    let scale = if present_weight > 0.0 {
        1.0 / present_weight
    } else {
        1.0
    };
    let composite: f64 = present.iter().map(|(_, w, n)| w * scale * n).sum();
    let _ = missing_weight; // recorded for future explain output

    let baseline_composite = baseline.map(|b| b.composite).unwrap_or(1.0);
    let delta = baseline_composite - composite;

    // Per-component minimum guard.
    if let Some((hot_name, hot_norm)) = present
        .iter()
        .filter(|(_, _, n)| *n < PER_COMPONENT_MIN_GUARD)
        .min_by(|a, b| a.2.partial_cmp(&b.2).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(n, _, normed)| (n.to_string(), *normed))
    {
        let per_component = present
            .iter()
            .map(|(n, _, normed)| (n.to_string(), *normed))
            .collect();
        return Ok(ScoreVerdict::Regression {
            composite,
            delta: 1.0 - hot_norm,
            hot_metric: hot_name,
            per_component,
        });
    }

    if delta > DEFAULT_REGRESSION_FLOOR {
        // Find the worst-normalized present metric to attribute as
        // the hot path of the regression.
        let hot = present
            .iter()
            .min_by(|a, b| a.2.partial_cmp(&b.2).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(n, _, _)| n.to_string())
            .unwrap_or_else(|| "composite".to_string());
        let per_component = present
            .iter()
            .map(|(n, _, normed)| (n.to_string(), *normed))
            .collect();
        return Ok(ScoreVerdict::Regression {
            composite,
            delta,
            hot_metric: hot,
            per_component,
        });
    }

    Ok(ScoreVerdict::Pass { composite })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::Stack;
    use crate::metrics::{Direction, MetricSample};
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn report_with(samples: Vec<(&str, f64, Direction)>) -> PerfReport {
        let mut map = BTreeMap::new();
        for (name, value, direction) in samples {
            map.insert(
                name.to_string(),
                MetricSample {
                    value,
                    unit: "test".into(),
                    direction,
                    adapter: "rust".into(),
                    notes: None,
                },
            );
        }
        PerfReport {
            schema_version: 1,
            captured_at: Utc::now(),
            project_root: "/tmp".into(),
            stack: Stack::Rust,
            samples: map,
            notes: BTreeMap::new(),
            correctness_ok: true,
            correctness_failure: None,
        }
    }

    fn baseline_with(components: Vec<(&str, f64)>) -> Baseline {
        let mut map = BTreeMap::new();
        for (k, v) in &components {
            map.insert((*k).to_string(), *v);
        }
        Baseline {
            schema_version: 1,
            updated_at: Utc::now(),
            composite: 1.0,
            components: map,
            machine_class: Some("test".into()),
            history: vec![],
        }
    }

    #[test]
    fn baseline_init_when_no_baseline() {
        let r = report_with(vec![("alloc_per_op", 100.0, Direction::LowerIsBetter)]);
        let verdict = score(&r, None).unwrap();
        match verdict {
            ScoreVerdict::BaselineInit { composite } => assert!(composite > 0.0),
            other => panic!("expected BaselineInit, got {other:?}"),
        }
    }

    #[test]
    fn pass_when_match() {
        let r = report_with(vec![("alloc_per_op", 100.0, Direction::LowerIsBetter)]);
        let b = baseline_with(vec![("alloc_per_op", 100.0)]);
        let verdict = score(&r, Some(&b)).unwrap();
        assert!(matches!(verdict, ScoreVerdict::Pass { .. }));
    }

    #[test]
    fn regression_on_below_min_guard() {
        // Improved composite but one component falls below 0.85.
        let r = report_with(vec![
            ("alloc_per_op", 200.0, Direction::LowerIsBetter), // 0.5 (regression)
            ("critical_path_ops", 50.0, Direction::LowerIsBetter), // 2.0 (huge improvement)
        ]);
        let b = baseline_with(vec![
            ("alloc_per_op", 100.0),
            ("critical_path_ops", 100.0),
        ]);
        let verdict = score(&r, Some(&b)).unwrap();
        assert!(matches!(verdict, ScoreVerdict::Regression { .. }));
    }

    #[test]
    fn pass_on_no_present_metrics() {
        // All samples zero → adapter had no signal → neutral pass.
        let r = report_with(vec![("alloc_per_op", 0.0, Direction::LowerIsBetter)]);
        let b = baseline_with(vec![("alloc_per_op", 100.0)]);
        let verdict = score(&r, Some(&b)).unwrap();
        assert!(matches!(verdict, ScoreVerdict::Pass { .. }));
    }
}
