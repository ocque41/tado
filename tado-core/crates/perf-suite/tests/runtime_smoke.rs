//! Runtime module smoke tests — verify the shared spawn helpers
//! (cold-start, RSS, syscalls, run-with-budget) work end-to-end.
//! These exercise the real OS process API; tests must succeed on
//! macOS + Linux without sudo.

use perf_suite::runtime::{cold_start_lines, rss_ratio, run_with_budget, SpawnTarget};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

fn shell_target(script: &str) -> SpawnTarget {
    SpawnTarget {
        program: PathBuf::from("sh"),
        args: vec!["-c".into(), script.into()],
        working_dir: std::env::temp_dir(),
        env: vec![],
    }
}

#[test]
fn run_with_budget_returns_quick_output() {
    let mut cmd = Command::new("sh");
    cmd.args(["-c", "printf 'hi'"]);
    let out = run_with_budget(cmd, Some(Duration::from_secs(2))).unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hi");
}

#[test]
fn run_with_budget_kills_runaway() {
    let mut cmd = Command::new("sh");
    cmd.args(["-c", "sleep 30"]);
    let result = run_with_budget(cmd, Some(Duration::from_millis(500)));
    assert!(result.is_err(), "expected timeout error, got {result:?}");
}

#[test]
fn cold_start_lines_counts_until_quiet() {
    // 4 lines emitted then the process sleeps. Within a 2 s budget
    // the count should land at 4.
    let target = shell_target("echo a; echo b; echo c; echo d; sleep 5");
    let (count, _) = cold_start_lines(&target, Duration::from_secs(2));
    assert!(count >= 4.0 && count <= 5.0, "expected ~4 lines, got {count}");
}

#[test]
fn cold_start_lines_stops_at_ready_sentinel() {
    // 3 lines, the third is "ready" — should stop after 3.
    let target = shell_target("echo init; echo loading; echo ready; sleep 30");
    let (count, _) = cold_start_lines(&target, Duration::from_secs(3));
    assert!(count >= 1.0 && count <= 3.0, "expected stop at sentinel (≤3), got {count}");
}

#[test]
fn cold_start_handles_no_output() {
    let target = shell_target("sleep 1");
    let (count, note) = cold_start_lines(&target, Duration::from_millis(500));
    assert_eq!(count, 0.0);
    assert!(note.unwrap_or_default().contains("no stdout"));
}

#[test]
fn rss_ratio_returns_neutral_when_target_exits_immediately() {
    let target = shell_target("exit 0");
    let (ratio, _) = rss_ratio(&target, Duration::from_secs(3));
    // Process exited before we could sample → returns neutral 1.0.
    assert!(ratio == 1.0, "expected neutral 1.0, got {ratio}");
}

#[test]
fn rss_ratio_rejects_too_small_budget() {
    let target = shell_target("sleep 30");
    let (ratio, note) = rss_ratio(&target, Duration::from_secs(2));
    assert_eq!(ratio, 1.0);
    assert!(note.unwrap_or_default().contains("budget too small"));
}
