//! Off-main reader for one Eternal run's on-disk state.
//!
//! This is the Rust-side counterpart to the Swift
//! `EternalRunStateCache.readSnapshot(fromDirPath:)` helper.
//! Replaces the synchronous `Data(contentsOf:)` + `JSONDecoder.decode`
//! chain that the SwiftUI 2-second `TimelineView` tick used to do on
//! @MainActor — the bug that froze the canvas on panel-driven
//! Eternal starts (debug plan rev 4).
//!
//! Contract:
//! * One pass over the run dir per call. Bundles every file read into
//!   one IO trip so the caller pays at most three syscalls + one
//!   `metrics.jsonl` line scan per ingest.
//! * Tolerant: missing files / malformed JSON degrade to default
//!   field values. The caller (Swift cache + view) treats absence as
//!   "not yet" rather than as an error — matches the existing
//!   `EternalState` decoder discipline (additive migrations rule).
//! * Pure: no tokio, no global state, no FFI side effects in the
//!   library layer. The FFI shim (`ffi.rs`) is a thin C-ABI wrapper
//!   the Swift cache calls through `tado-terminal`'s re-export.

//! C-ABI: see `tado-terminal/src/eternal_state_ffi.rs` for the
//! `tado_eternal_state_snapshot` / `_string_free` shims that ship
//! inside the unified `libtado_core.a` the Swift app links.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Mirror of Swift's `EternalState` Codable. Only the fields the
/// view actually reads are lifted; extra columns coming back from
/// hooks are tolerated by serde via `#[serde(default)]` +
/// `flatten`-free shape.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EternalStateJson {
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default, rename = "startedAt")]
    pub started_at: f64,
    #[serde(default, rename = "lastActivityAt")]
    pub last_activity_at: f64,
    #[serde(default)]
    pub iterations: i64,
    #[serde(default)]
    pub sprints: i64,
    #[serde(default)]
    pub compactions: i64,
    #[serde(default = "default_phase")]
    pub phase: String,
    #[serde(default, rename = "lastError")]
    pub last_error: Option<String>,
    #[serde(default, rename = "lastProgressNote")]
    pub last_progress_note: Option<String>,
    #[serde(default, rename = "completionMarker")]
    pub completion_marker: String,
    #[serde(default, rename = "sprintMarker")]
    pub sprint_marker: String,
    #[serde(default, rename = "perfCycles")]
    pub perf_cycles: i64,
    #[serde(default, rename = "lastPerfScore")]
    pub last_perf_score: Option<f64>,
    #[serde(default, rename = "perfRegressionDelta")]
    pub perf_regression_delta: Option<f64>,
    #[serde(default, rename = "lastPerfReportPath")]
    pub last_perf_report_path: Option<String>,
    #[serde(default, rename = "sprintCycles")]
    pub sprint_cycles: i64,
    #[serde(default, rename = "lastSprintScore")]
    pub last_sprint_score: Option<f64>,
    #[serde(default, rename = "sprintRegressionDelta")]
    pub sprint_regression_delta: Option<f64>,
    #[serde(default, rename = "lastSprintReportPath")]
    pub last_sprint_report_path: Option<String>,
    /// Free-form metric value. Hooks emit either a number or a
    /// short label; the Swift side expects `MetricValue` (number or
    /// text). We keep the raw JSON value here and let the caller's
    /// own decoder pick a representation. `Value` round-trips
    /// untouched through serde_json, so nothing is lost.
    #[serde(default, rename = "lastMetric")]
    pub last_metric: Option<serde_json::Value>,
}

fn default_mode() -> String {
    "mega".to_string()
}

fn default_phase() -> String {
    "working".to_string()
}

/// Snapshot delivered to the Swift cache. Mirrors
/// `EternalRunStateCache.Snapshot` field-for-field. The Rust side
/// owns parsing + scanning so the Swift @MainActor never pays the
/// IO; the Swift cache then formats `last_metric_value` through its
/// existing `MetricValue.display` if it wants a display string —
/// keeping the formatter authoritative on the Swift side avoids
/// byte-drift between the two implementations.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EternalRunStateSnapshot {
    /// Parsed `state.json`. `None` while the worker hasn't written
    /// the file yet (architect-only runs, just-spawned runs).
    pub state: Option<EternalStateJson>,
    /// `crafted.md` exists on disk — the architect's "done" signal.
    pub crafted_exists: bool,
    /// `stop-flag` exists — short-circuits the running pill so the
    /// UI flips off "running" the instant the user clicks Stop.
    pub stop_flag_exists: bool,
    /// Total non-malformed rows in `metrics.jsonl`. Used as a
    /// "did the wrapper start logging metrics yet?" signal.
    pub metrics_count: u64,
    /// Raw `metric` value of the most recently logged sample, as
    /// JSON (number or string). Swift's `MetricValue` re-decodes
    /// this through its existing `Codable` initializer so the
    /// display formatting stays single-source. `None` when the file
    /// is empty / missing / every row is malformed.
    pub last_metric_value: Option<serde_json::Value>,
    /// Highest `sprint` field seen across `metrics.jsonl`. The view
    /// computes `effectiveSprint = max(state.sprints, this)` so a
    /// bad write race in `state.json` doesn't stall the SPRINT
    /// counter.
    pub max_metric_sprint: i64,
}

/// Read every artifact for one run dir into one snapshot.
///
/// Path layout (mirrors `EternalService` Swift helpers):
/// ```text
/// <run_dir>/state.json
/// <run_dir>/crafted.md
/// <run_dir>/stop-flag
/// <run_dir>/metrics.jsonl
/// ```
///
/// Errors are absorbed: `state.json` missing → `state = None`;
/// `metrics.jsonl` corrupt line → that line is skipped. The caller
/// never sees a `Result` because there's no actionable failure here
/// — the view simply renders an empty snapshot until the next
/// FileWatcher firing brings real data.
pub fn read_run_snapshot(run_dir: &Path) -> EternalRunStateSnapshot {
    let state_path = run_dir.join("state.json");
    let crafted_path = run_dir.join("crafted.md");
    let stop_flag_path = run_dir.join("stop-flag");
    let metrics_path = run_dir.join("metrics.jsonl");

    let state: Option<EternalStateJson> = std::fs::read(&state_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());

    let crafted_exists = crafted_path.exists();
    let stop_flag_exists = stop_flag_path.exists();

    let mut metrics_count = 0u64;
    let mut last_metric_value: Option<serde_json::Value> = None;
    let mut max_metric_sprint = 0i64;

    if let Ok(text) = std::fs::read_to_string(&metrics_path) {
        for line in text.split(|c| c == '\n' || c == '\r') {
            if line.is_empty() {
                continue;
            }
            let Ok(row) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            metrics_count += 1;
            // Sprint number — accept either `sprint` or `sprint_n`,
            // either int or float.
            if let Some(n) = row.get("sprint").and_then(|v| v.as_i64()) {
                if n > max_metric_sprint {
                    max_metric_sprint = n;
                }
            } else if let Some(n) = row.get("sprint_n").and_then(|v| v.as_i64()) {
                if n > max_metric_sprint {
                    max_metric_sprint = n;
                }
            } else if let Some(n) = row.get("sprint_n").and_then(|v| v.as_f64()) {
                let truncated = n as i64;
                if truncated > max_metric_sprint {
                    max_metric_sprint = truncated;
                }
            }
            // Last metric value — prefer `metric` (free-form
            // number-or-text), fall back to `composite` (number).
            if let Some(m) = row.get("metric") {
                last_metric_value = Some(m.clone());
            } else if let Some(c) = row.get("composite") {
                last_metric_value = Some(c.clone());
            }
        }
    }

    EternalRunStateSnapshot {
        state,
        crafted_exists,
        stop_flag_exists,
        metrics_count,
        last_metric_value,
        max_metric_sprint,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn empty_run_dir_returns_default_snapshot() {
        let dir = tempdir().unwrap();
        let snap = read_run_snapshot(dir.path());
        assert!(snap.state.is_none());
        assert!(!snap.crafted_exists);
        assert!(!snap.stop_flag_exists);
        assert_eq!(snap.metrics_count, 0);
        assert!(snap.last_metric_value.is_none());
        assert_eq!(snap.max_metric_sprint, 0);
    }

    #[test]
    fn architect_only_run_with_crafted_md() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("crafted.md"), "# crafted").unwrap();
        let snap = read_run_snapshot(dir.path());
        assert!(snap.state.is_none());
        assert!(snap.crafted_exists);
    }

    #[test]
    fn running_run_decodes_state_and_metrics() {
        let dir = tempdir().unwrap();
        let state = r#"{
            "mode": "sprint",
            "startedAt": 1700000000.0,
            "lastActivityAt": 1700000010.0,
            "iterations": 7,
            "sprints": 2,
            "phase": "working"
        }"#;
        fs::write(dir.path().join("state.json"), state).unwrap();
        let metrics = "{\"sprint\": 1, \"timestamp\": \"a\", \"metric\": 0.5}\n{\"sprint\": 2, \"timestamp\": \"b\", \"metric\": \"pass\"}\n";
        fs::write(dir.path().join("metrics.jsonl"), metrics).unwrap();
        let snap = read_run_snapshot(dir.path());
        let st = snap.state.expect("state should decode");
        assert_eq!(st.mode, "sprint");
        assert_eq!(st.iterations, 7);
        assert_eq!(st.sprints, 2);
        assert_eq!(st.phase, "working");
        assert_eq!(snap.metrics_count, 2);
        assert_eq!(
            snap.last_metric_value,
            Some(serde_json::Value::String("pass".to_string()))
        );
        assert_eq!(snap.max_metric_sprint, 2);
    }

    #[test]
    fn terminal_run_decodes_completed_phase() {
        let dir = tempdir().unwrap();
        fs::write(
            dir.path().join("state.json"),
            r#"{"phase": "completed", "iterations": 12}"#,
        )
        .unwrap();
        let snap = read_run_snapshot(dir.path());
        assert_eq!(snap.state.unwrap().phase, "completed");
    }

    #[test]
    fn malformed_metrics_lines_are_skipped() {
        let dir = tempdir().unwrap();
        let metrics = "not-json\n{\"sprint\": 5, \"metric\": 1.0}\n";
        fs::write(dir.path().join("metrics.jsonl"), metrics).unwrap();
        let snap = read_run_snapshot(dir.path());
        assert_eq!(snap.metrics_count, 1);
        assert_eq!(snap.max_metric_sprint, 5);
    }

    #[test]
    fn stop_flag_presence_is_reported() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("stop-flag"), b"").unwrap();
        let snap = read_run_snapshot(dir.path());
        assert!(snap.stop_flag_exists);
    }

    #[test]
    fn malformed_state_json_returns_none_without_panicking() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("state.json"), "not json at all").unwrap();
        let snap = read_run_snapshot(dir.path());
        assert!(snap.state.is_none());
    }

    #[test]
    fn composite_only_metrics_row_falls_back_to_composite_field() {
        let dir = tempdir().unwrap();
        let metrics = "{\"sprint\": 3, \"composite\": 1.42}\n";
        fs::write(dir.path().join("metrics.jsonl"), metrics).unwrap();
        let snap = read_run_snapshot(dir.path());
        assert_eq!(snap.metrics_count, 1);
        // Routed via `composite`; round-trip preserves the number.
        let raw = snap.last_metric_value.as_ref().expect("metric present");
        assert!((raw.as_f64().unwrap() - 1.42).abs() < 1e-9);
    }
}
