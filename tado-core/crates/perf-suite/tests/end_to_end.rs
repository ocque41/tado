//! End-to-end integration tests for perf-suite.
//!
//! Each test exercises a full measure → score → baseline cycle as
//! the perf-gate.sh hook would, verifying contract behaviors:
//!
//! - PASS path: composite >= baseline → baseline writes → next run
//!   sees the new high-water mark.
//! - REGRESSION path: any component falls below 0.85 → verdict
//!   regression even if composite is fine.
//! - BASELINE-INIT: first run for a project has no baseline file.
//! - Machine drift: refusing to update when machine_class doesn't
//!   match (override via TADO_PERF_ALLOW_DRIFT).

use chrono::Utc;
use perf_suite::adapters::Stack;
use perf_suite::baseline::{init_from, machine_class, read_baseline, update_with, write_baseline};
use perf_suite::metrics::{Direction, MetricSample};
use perf_suite::report::PerfReport;
use perf_suite::scoring::{score, ScoreVerdict};
use std::collections::BTreeMap;
use std::path::PathBuf;

fn tmpfile(name: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "perf-suite-it-{}-{}",
        name,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    p
}

fn report_with(samples: Vec<(&str, f64)>) -> PerfReport {
    let mut map = BTreeMap::new();
    for (name, value) in samples {
        map.insert(
            name.to_string(),
            MetricSample {
                value,
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
        project_root: "/tmp/it".into(),
        stack: Stack::Rust,
        samples: map,
        notes: BTreeMap::new(),
        correctness_ok: true,
        correctness_failure: None,
    }
}

#[test]
fn full_cycle_baseline_init_then_pass() {
    let path = tmpfile("baseline-init.json");

    // Initial run: no baseline.
    let r1 = report_with(vec![
        ("alloc_per_op", 100.0),
        ("critical_path_ops", 100.0),
    ]);
    let v1 = score(&r1, None).unwrap();
    let composite = match v1 {
        ScoreVerdict::BaselineInit { composite } => composite,
        other => panic!("expected BaselineInit, got {other:?}"),
    };
    let b1 = init_from(&r1, composite);
    write_baseline(&path, &b1).unwrap();

    // Second run: matches baseline → PASS.
    let r2 = report_with(vec![
        ("alloc_per_op", 100.0),
        ("critical_path_ops", 100.0),
    ]);
    let stored = read_baseline(&path).unwrap().unwrap();
    let v2 = score(&r2, Some(&stored)).unwrap();
    assert!(matches!(v2, ScoreVerdict::Pass { .. }));

    let _ = std::fs::remove_file(&path);
}

#[test]
fn baseline_ratchets_only_in_better_direction() {
    let r1 = report_with(vec![("alloc_per_op", 100.0), ("critical_path_ops", 100.0)]);
    let b1 = init_from(&r1, 1.0);

    // Update with a better report — both metrics improved.
    let r2 = report_with(vec![("alloc_per_op", 80.0), ("critical_path_ops", 90.0)]);
    let b2 = update_with(&b1, &r2, 1.2);
    assert_eq!(b2.components["alloc_per_op"], 80.0);
    assert_eq!(b2.components["critical_path_ops"], 90.0);
    assert_eq!(b2.composite, 1.2);
    assert_eq!(b2.history.len(), 2);

    // Update with mixed — alloc improved more, critical regressed.
    // Per-component ratchet keeps the better one.
    let r3 = report_with(vec![("alloc_per_op", 70.0), ("critical_path_ops", 200.0)]);
    let b3 = update_with(&b2, &r3, 1.3);
    assert_eq!(b3.components["alloc_per_op"], 70.0);
    assert_eq!(b3.components["critical_path_ops"], 90.0); // didn't regress
}

#[test]
fn min_guard_fails_even_with_strong_composite() {
    let baseline = init_from(
        &report_with(vec![
            ("alloc_per_op", 100.0),
            ("critical_path_ops", 100.0),
        ]),
        1.0,
    );
    // Massive critical_path_ops improvement, alloc collapsed to 0.5x baseline.
    let r = report_with(vec![
        ("alloc_per_op", 200.0),  // 0.5 normalized
        ("critical_path_ops", 50.0), // 2.0 normalized
    ]);
    let v = score(&r, Some(&baseline)).unwrap();
    assert!(matches!(v, ScoreVerdict::Regression { .. }));
}

#[test]
fn machine_class_drift_detected() {
    let r = report_with(vec![("alloc_per_op", 100.0)]);
    let mut baseline = init_from(&r, 1.0);
    baseline.machine_class = Some("alien-machine".into());
    assert!(perf_suite::baseline::machine_drift(&baseline));

    baseline.machine_class = Some(machine_class());
    assert!(!perf_suite::baseline::machine_drift(&baseline));

    baseline.machine_class = None;
    assert!(!perf_suite::baseline::machine_drift(&baseline));
}

#[test]
fn missing_metrics_redistribute_weight() {
    // Only one of the eight metrics is present. The composite should
    // still compute (via the redistribution path), and a matching
    // value should PASS.
    let r = report_with(vec![("alloc_per_op", 100.0)]);
    let baseline = init_from(&r, 1.0);
    let v = score(&r, Some(&baseline)).unwrap();
    assert!(matches!(v, ScoreVerdict::Pass { .. }));
}

#[test]
fn correctness_failure_propagates_to_score() {
    let mut r = report_with(vec![("alloc_per_op", 100.0)]);
    r.correctness_ok = false;
    r.correctness_failure = Some("tests broke".into());
    // Score isn't even called — the gate refuses earlier. Verify the
    // serialized report carries the failure across read/write.
    let path = tmpfile("correctness-fail.json");
    r.write_to(&path).unwrap();
    let read = PerfReport::read_from(&path).unwrap();
    assert!(!read.correctness_ok);
    assert_eq!(read.correctness_failure.as_deref(), Some("tests broke"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn one_line_verdict_format_is_stable() {
    let r = report_with(vec![("alloc_per_op", 100.0), ("critical_path_ops", 100.0)]);
    let baseline = init_from(&r, 1.0);
    let v = score(&r, Some(&baseline)).unwrap();
    let line = v.one_line();
    // The bash hook depends on this prefix shape.
    assert!(line.starts_with("PERF: PASS composite="), "got: {line}");
    assert!(line.contains("composite="));
}

#[test]
fn baseline_init_contract_line() {
    let r = report_with(vec![("alloc_per_op", 100.0)]);
    let v = score(&r, None).unwrap();
    let line = v.one_line();
    assert!(line.starts_with("PERF: BASELINE-INIT composite="), "got: {line}");
}

#[test]
fn regression_contract_line_includes_hot_metric() {
    let baseline = init_from(
        &report_with(vec![
            ("alloc_per_op", 100.0),
            ("critical_path_ops", 100.0),
        ]),
        1.0,
    );
    let r = report_with(vec![
        ("alloc_per_op", 1000.0),  // 0.1 normalized — well below 0.85
        ("critical_path_ops", 100.0),
    ]);
    let v = score(&r, Some(&baseline)).unwrap();
    let line = v.one_line();
    assert!(line.starts_with("PERF: REGRESSION"), "got: {line}");
    assert!(line.contains("hot=alloc_per_op"));
}
