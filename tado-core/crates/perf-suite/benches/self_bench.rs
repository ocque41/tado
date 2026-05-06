//! perf-suite's own benchmarks. Two reasons to have these:
//!
//! 1. The suite must be FAST — it runs every Eternal worker
//!    iteration in perf mode, so scoring + composite + proposal
//!    generation must complete in single-digit seconds. We bench the
//!    hot path so a regression in the gate's own runtime gets caught
//!    before it inflates iteration cost.
//!
//! 2. The suite produces deterministic outputs we can dogfood: the
//!    `algo_complexity` slope-fitting helper has tests that prove
//!    the math, but the bench validates that fitting 1000-point
//!    series is also fast.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use perf_suite::adapters::Stack;
use perf_suite::baseline::{init_from, update_with};
use perf_suite::metrics::{algo_complexity, Direction, MetricSample};
use perf_suite::report::PerfReport;
use perf_suite::scoring::score;
use std::collections::BTreeMap;

fn bench_slope_fit(c: &mut Criterion) {
    let small: Vec<(f64, f64)> = vec![(1.0, 1.0), (10.0, 10.0), (100.0, 100.0), (1000.0, 1000.0)];
    let large: Vec<(f64, f64)> = (1..1000).map(|i| (i as f64, (i as f64).powf(1.5))).collect();

    c.bench_function("algo_complexity::fit_loglog_slope/n=4", |b| {
        b.iter(|| algo_complexity::fit_loglog_slope(black_box(&small)))
    });
    c.bench_function("algo_complexity::fit_loglog_slope/n=999", |b| {
        b.iter(|| algo_complexity::fit_loglog_slope(black_box(&large)))
    });
}

fn bench_score(c: &mut Criterion) {
    let report = sample_report();
    let baseline = init_from(&report, 1.0);
    c.bench_function("scoring::score/8 metrics", |b| {
        b.iter(|| score(black_box(&report), Some(black_box(&baseline))))
    });
}

fn bench_baseline_update(c: &mut Criterion) {
    let report = sample_report();
    let baseline = init_from(&report, 1.0);
    c.bench_function("baseline::update_with/8 components", |b| {
        b.iter(|| update_with(black_box(&baseline), black_box(&report), 1.0))
    });
}

fn sample_report() -> PerfReport {
    use chrono::Utc;
    let mut samples = BTreeMap::new();
    for (name, _, _) in perf_suite::metrics::registry() {
        samples.insert(
            name.to_string(),
            MetricSample {
                value: 1.0,
                unit: "test".into(),
                direction: Direction::LowerIsBetter,
                adapter: "rust".into(),
                notes: None,
            },
        );
    }
    PerfReport {
        schema_version: 1,
        captured_at: Utc::now(),
        project_root: "/tmp/x".into(),
        stack: Stack::Rust,
        samples,
        notes: BTreeMap::new(),
        correctness_ok: true,
        correctness_failure: None,
    }
}

criterion_group!(benches, bench_slope_fit, bench_score, bench_baseline_update);
criterion_main!(benches);
