//! Adapter integration tests using the fixture projects.
//!
//! These tests prove the adapters can:
//!   1. Detect their stack from the fixture's root files.
//!   2. Produce a non-zero count for at least one source-tree
//!      regex-based metric (DB or xproc).
//!
//! They DO NOT shell out to cargo/swift/npm/pytest/go — those are
//! verified per-stack in unit tests by the adapters' own scan helpers.
//! Here we just verify the wiring + fixture content survives.

use perf_suite::adapters::{detect_adapter, detect_stack, Stack};
use perf_suite::MeasurementContext;
use std::path::PathBuf;

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn ctx_for(stack: &str) -> MeasurementContext {
    let project_root = fixtures_dir().join(stack);
    let run_dir = std::env::temp_dir().join(format!("perf-suite-fixtures-{stack}"));
    let _ = std::fs::create_dir_all(&run_dir);
    MeasurementContext {
        project_root: project_root.clone(),
        run_dir,
        stack: detect_stack(&project_root),
        per_metric_budget_secs: Some(2),
    }
}

#[test]
fn fixture_rust_detects_rust_stack() {
    let ctx = ctx_for("rust");
    assert_eq!(ctx.stack, Stack::Rust);
    assert!(detect_adapter(&ctx.project_root).is_some());
}

#[test]
fn fixture_node_detects_node_stack() {
    let ctx = ctx_for("node");
    assert_eq!(ctx.stack, Stack::Node);
}

#[test]
fn fixture_python_detects_python_stack() {
    let ctx = ctx_for("python");
    assert_eq!(ctx.stack, Stack::Python);
}

#[test]
fn fixture_go_detects_go_stack() {
    let ctx = ctx_for("go");
    assert_eq!(ctx.stack, Stack::Go);
}

#[test]
fn fixture_swift_detects_swift_stack() {
    let ctx = ctx_for("swift");
    assert_eq!(ctx.stack, Stack::Swift);
}

/// Polyglot fixture has both Cargo.toml and package.json so the
/// detector picks Polyglot.
#[test]
fn fixture_polyglot_detects_polyglot_stack() {
    let dir = fixtures_dir().join("polyglot");
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(dir.join("Cargo.toml"), "[package]\nname='p'\nversion='0.0.1'\n");
    let _ = std::fs::write(dir.join("package.json"), "{}");
    assert_eq!(detect_stack(&dir), Stack::Polyglot);
}

#[test]
fn rust_fixture_has_db_pattern() {
    use perf_suite::proposal::generate_proposals;
    use perf_suite::report::PerfReport;
    use chrono::Utc;
    use std::collections::BTreeMap;

    let dir = fixtures_dir().join("rust");
    let report = PerfReport {
        schema_version: 1,
        captured_at: Utc::now(),
        project_root: dir.display().to_string(),
        stack: Stack::Rust,
        samples: BTreeMap::new(),
        notes: BTreeMap::new(),
        correctness_ok: true,
        correctness_failure: None,
    };
    // Use --since-last-commit=false so the proposal generator scans
    // the whole tree (the fixture isn't in a separate git repo).
    let proposals = generate_proposals(&dir, &report, false, 50);
    // The fixture's main.rs has Vec::new(), .clone() in a loop, and
    // rusqlite-style execute calls — at least one proposal should fire.
    assert!(!proposals.is_empty(), "expected ≥1 proposal from Rust fixture, got 0");
}

#[test]
fn node_fixture_has_xproc_pattern() {
    use perf_suite::proposal::generate_proposals;
    use perf_suite::report::PerfReport;
    use chrono::Utc;
    use std::collections::BTreeMap;

    let dir = fixtures_dir().join("node");
    let report = PerfReport {
        schema_version: 1,
        captured_at: Utc::now(),
        project_root: dir.display().to_string(),
        stack: Stack::Node,
        samples: BTreeMap::new(),
        notes: BTreeMap::new(),
        correctness_ok: true,
        correctness_failure: None,
    };
    let proposals = generate_proposals(&dir, &report, false, 50);
    assert!(!proposals.is_empty(), "expected ≥1 proposal from Node fixture");
}
