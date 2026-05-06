//! Algorithmic complexity — Big-O scaling regression detector.
//!
//! Synthetic-input scaling test: run the project's hot function (or
//! benchmark target) with input sizes N = 1, 10, 100, 1000, fit a
//! log-log slope, and report the slope as the value.
//!
//! Slope ~1.0 = linear, ~2.0 = quadratic, ~3.0 = cubic. A regression
//! from 1.0 → 1.7 says you accidentally introduced super-linear work.
//!
//! Device-independence: a slope is a property of the algorithm, not
//! the CPU. A linear → quadratic regression shows up identically on
//! M2 and M5 silicon.
//!
//! Adapter responsibility: parse the bench output for per-N timings,
//! call `fit_loglog_slope` to compress the curve to a single slope.

use super::{Direction, MetricSample};

pub const NAME: &str = "algo_complexity";
pub const WEIGHT: f64 = 0.18;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "slope";

/// Fit the slope of a log-log line through (N_i, time_i) pairs.
/// Returns the slope using ordinary least squares on `log10(N)` and
/// `log10(time)`. Caller filters out N=0 / time=0 pairs.
pub fn fit_loglog_slope(pairs: &[(f64, f64)]) -> Option<f64> {
    let valid: Vec<(f64, f64)> = pairs
        .iter()
        .filter(|(n, t)| *n > 0.0 && *t > 0.0)
        .map(|(n, t)| (n.log10(), t.log10()))
        .collect();
    if valid.len() < 2 {
        return None;
    }
    let n = valid.len() as f64;
    let mean_x = valid.iter().map(|(x, _)| x).sum::<f64>() / n;
    let mean_y = valid.iter().map(|(_, y)| y).sum::<f64>() / n;
    let num: f64 = valid
        .iter()
        .map(|(x, y)| (x - mean_x) * (y - mean_y))
        .sum();
    let den: f64 = valid.iter().map(|(x, _)| (x - mean_x).powi(2)).sum();
    if den.abs() < f64::EPSILON {
        return None;
    }
    Some(num / den)
}

/// Build a `MetricSample` from a fitted slope.
pub fn sample_from_slope(slope: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value: slope,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slope_of_linear_is_one() {
        let pairs = vec![(1.0, 1.0), (10.0, 10.0), (100.0, 100.0), (1000.0, 1000.0)];
        let slope = fit_loglog_slope(&pairs).unwrap();
        assert!((slope - 1.0).abs() < 0.01, "got {slope}");
    }

    #[test]
    fn slope_of_quadratic_is_two() {
        let pairs = vec![(1.0, 1.0), (10.0, 100.0), (100.0, 10_000.0)];
        let slope = fit_loglog_slope(&pairs).unwrap();
        assert!((slope - 2.0).abs() < 0.01, "got {slope}");
    }

    #[test]
    fn empty_or_singleton_returns_none() {
        assert!(fit_loglog_slope(&[]).is_none());
        assert!(fit_loglog_slope(&[(1.0, 1.0)]).is_none());
    }

    #[test]
    fn zero_inputs_filtered() {
        let pairs = vec![(0.0, 1.0), (1.0, 0.0), (10.0, 10.0), (100.0, 100.0)];
        let slope = fit_loglog_slope(&pairs).unwrap();
        assert!((slope - 1.0).abs() < 0.01);
    }
}
