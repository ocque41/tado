//! Go stack adapter — production implementation.
//!
//! Detection: `go.mod` in project root.
//!
//! Correctness gate: `go test ./...`.
//!
//! Per-metric measurement:
//! - **algo_complexity**: parses `go test -bench=. -benchmem` output
//!   for benchmarks grouped by `_n<N>` suffix; fits log-log slope.
//! - **alloc_per_op**: parses `B/op` and `allocs/op` columns from the
//!   same `-benchmem` output. Returns mean allocs/op.
//! - **critical_path_ops**: skipped (pprof too project-specific).
//! - **io_syscalls_per_op**: dtrace/strace wrap, opt-in.
//! - **db_query_cost**: counts `db.Exec` / `db.Query` patterns;
//!   subtracts patterns inside `tx, err := db.Begin()` envelopes.
//! - **xproc_roundtrips**: counts `exec.Command`, `http.Get`,
//!   `net.Dial` patterns.
//! - **cold_start_ops**: spawn the built binary, count stdout lines.
//! - **steady_state_rss_ratio**: ps-sampling on the spawned go binary.

use super::{Adapter, AdapterError, Stack};
use crate::metrics::{
    algo_complexity, alloc_per_op, cold_start_ops, critical_path_ops, db_query_cost,
    io_syscalls_per_op, steady_state_rss_ratio, xproc_roundtrips, MetricSample,
};
use crate::runtime::{cold_start_lines, io_syscalls, rss_ratio, run_with_budget, SpawnTarget, which};
use crate::MeasurementContext;
use regex::Regex;
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

pub struct GoAdapter;

impl Adapter for GoAdapter {
    fn stack(&self) -> Stack {
        Stack::Go
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        let output = Command::new("go")
            .args(["test", "./..."])
            .current_dir(&ctx.project_root)
            .output()?;
        if output.status.success() {
            return Ok(());
        }
        Err(AdapterError::Correctness {
            stack: Stack::Go,
            exit_code: output.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    fn measure(
        &self,
        ctx: &MeasurementContext,
    ) -> Result<(BTreeMap<String, MetricSample>, BTreeMap<String, String>), AdapterError> {
        let mut samples = BTreeMap::new();
        let mut notes = BTreeMap::new();

        let (slope, allocs, slope_note, allocs_note) = measure_go_benches(&ctx.project_root);
        samples.insert(
            algo_complexity::NAME.to_string(),
            algo_complexity::sample_from_slope(slope, "go", slope_note.clone()),
        );
        if let Some(n) = slope_note { notes.insert(algo_complexity::NAME.to_string(), n); }

        samples.insert(
            alloc_per_op::NAME.to_string(),
            alloc_per_op::sample(allocs, "go", allocs_note.clone()),
        );
        if let Some(n) = allocs_note { notes.insert(alloc_per_op::NAME.to_string(), n); }

        let (cp, cp_note) = measure_go_critical_path(&ctx.project_root, &ctx.run_dir);
        samples.insert(critical_path_ops::NAME.to_string(), critical_path_ops::sample(cp, "go", cp_note.clone()));
        if let Some(n) = cp_note { notes.insert(critical_path_ops::NAME.to_string(), n); }

        let (sys, sys_note) = measure_go_io_syscalls(&ctx.project_root);
        samples.insert(io_syscalls_per_op::NAME.to_string(), io_syscalls_per_op::sample(sys, "go", sys_note.clone()));
        if let Some(n) = sys_note { notes.insert(io_syscalls_per_op::NAME.to_string(), n); }

        let (db, db_note) = measure_go_db(&ctx.project_root);
        samples.insert(db_query_cost::NAME.to_string(), db_query_cost::sample(db, "go", db_note.clone()));
        if let Some(n) = db_note { notes.insert(db_query_cost::NAME.to_string(), n); }

        let (xp, xp_note) = measure_go_xproc(&ctx.project_root);
        samples.insert(xproc_roundtrips::NAME.to_string(), xproc_roundtrips::sample(xp, "go", xp_note.clone()));
        if let Some(n) = xp_note { notes.insert(xproc_roundtrips::NAME.to_string(), n); }

        let (cold, cold_note) = measure_go_cold_start(&ctx.project_root);
        samples.insert(cold_start_ops::NAME.to_string(), cold_start_ops::sample(cold, "go", cold_note.clone()));
        if let Some(n) = cold_note { notes.insert(cold_start_ops::NAME.to_string(), n); }

        let (rss, rss_note) = measure_go_rss(&ctx.project_root);
        samples.insert(steady_state_rss_ratio::NAME.to_string(), steady_state_rss_ratio::sample(rss, "go", rss_note.clone()));
        if let Some(n) = rss_note { notes.insert(steady_state_rss_ratio::NAME.to_string(), n); }

        Ok((samples, notes))
    }
}

/// Run `go test -bench=. -cpuprofile=...` and use `go tool pprof
/// -top -cum` to read the cumulative sample count.
fn measure_go_critical_path(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    if which("go").is_none() {
        return (0.0, Some("critical_path_ops: go toolchain not installed".into()));
    }
    let prof = run_dir.join("go-cpu.prof");
    let _ = std::fs::create_dir_all(run_dir);
    let mut cmd = Command::new("go");
    cmd.args(["test", "-bench=.", "-run=^$", "-cpuprofile"])
        .arg(&prof)
        .arg("./...")
        .current_dir(root);
    let _ = run_with_budget(cmd, Some(Duration::from_secs(30)));
    if !prof.exists() {
        return (0.0, Some("critical_path_ops: go test produced no cpuprofile".into()));
    }
    // `go tool pprof -top -cum` prints "Showing nodes accounting for ... of N total"
    let mut cmd = Command::new("go");
    cmd.args(["tool", "pprof", "-top", "-cum"])
        .arg(&prof)
        .current_dir(root);
    let output = match run_with_budget(cmd, Some(Duration::from_secs(15))) {
        Ok(out) => out,
        Err(e) => return (0.0, Some(format!("critical_path_ops: pprof failed ({e})"))),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let re = Regex::new(r"of\s+(\d+(?:\.\d+)?)\s*\w+\s+total").unwrap();
    if let Some(cap) = re.captures(&stdout) {
        if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
            return (n, Some(format!("critical_path_ops: pprof cumulative samples {n}")));
        }
    }
    (0.0, Some("critical_path_ops: pprof produced no total line".into()))
}

fn measure_go_io_syscalls(root: &Path) -> (f64, Option<String>) {
    let target = match go_target(root) {
        Some(t) => t,
        None => return (0.0, Some("io_syscalls_per_op: no go binary detected".into())),
    };
    io_syscalls(&target, Duration::from_secs(10))
}

fn measure_go_cold_start(root: &Path) -> (f64, Option<String>) {
    let target = match go_target(root) {
        Some(t) => t,
        None => return (0.0, Some("cold_start_ops: no go binary detected".into())),
    };
    cold_start_lines(&target, Duration::from_secs(10))
}

fn measure_go_rss(root: &Path) -> (f64, Option<String>) {
    let target = match go_target(root) {
        Some(t) => t,
        None => return (1.0, Some("steady_state_rss_ratio: no go binary detected".into())),
    };
    rss_ratio(&target, Duration::from_secs(10))
}

/// Build the project's main package and return a SpawnTarget. Looks
/// for `main.go` at root first; falls back to `cmd/<name>/main.go`
/// patterns that are conventional in Go projects.
fn go_target(root: &Path) -> Option<SpawnTarget> {
    let main = if root.join("main.go").exists() {
        root.to_path_buf()
    } else {
        let cmd_dir = root.join("cmd");
        if !cmd_dir.is_dir() { return None; }
        let entry = std::fs::read_dir(&cmd_dir).ok()?
            .flatten()
            .find(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))?;
        entry.path()
    };
    let bin_path = std::env::temp_dir().join(format!(
        "perf-suite-go-bin-{}",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let build = Command::new("go")
        .args(["build", "-o"])
        .arg(&bin_path)
        .arg(&main)
        .current_dir(root)
        .output()
        .ok()?;
    if !build.status.success() {
        return None;
    }
    Some(SpawnTarget {
        program: bin_path,
        args: vec![],
        working_dir: root.to_path_buf(),
        env: vec![],
    })
}

/// Run `go test -bench=. -benchmem ./...` once and parse both algo
/// scaling AND allocs/op from the output. Combined to amortize the
/// `go test -bench` startup cost.
fn measure_go_benches(root: &Path) -> (f64, f64, Option<String>, Option<String>) {
    let output = Command::new("go")
        .args(["test", "-bench=.", "-benchmem", "-run=^$", "./..."])
        .current_dir(root)
        .output();
    let Ok(output) = output else {
        return (
            1.0,
            0.0,
            Some("algo_complexity: go test -bench failed".into()),
            Some("alloc_per_op: go test -bench failed".into()),
        );
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    // Go bench line: "BenchmarkParse_n100-8     1000   1234 ns/op   500 B/op   3 allocs/op"
    let re = Regex::new(
        r"^Benchmark(\w+)_n(\d+)(?:-\d+)?\s+\d+\s+([\d.]+)\s+ns/op(?:\s+([\d.]+)\s+B/op)?(?:\s+([\d.]+)\s+allocs/op)?",
    ).unwrap();
    let mut groups: BTreeMap<String, Vec<(f64, f64)>> = BTreeMap::new();
    let mut allocs: Vec<f64> = Vec::new();
    for line in stdout.lines() {
        let Some(cap) = re.captures(line) else { continue };
        let base = cap.get(1).unwrap().as_str().to_string();
        let n: f64 = cap.get(2).unwrap().as_str().parse().unwrap_or(0.0);
        let ns: f64 = cap.get(3).unwrap().as_str().parse().unwrap_or(0.0);
        groups.entry(base.clone()).or_default().push((n, ns));
        if let Some(a) = cap.get(5) {
            if let Ok(v) = a.as_str().parse::<f64>() {
                allocs.push(v);
            }
        }
    }
    let mut worst: Option<(String, f64)> = None;
    for (group, points) in &groups {
        if points.len() < 2 { continue; }
        if let Some(slope) = algo_complexity::fit_loglog_slope(points) {
            if worst.as_ref().map(|(_, s)| slope > *s).unwrap_or(true) {
                worst = Some((group.clone(), slope));
            }
        }
    }
    let alloc_mean = if allocs.is_empty() { 0.0 } else { allocs.iter().sum::<f64>() / allocs.len() as f64 };
    let alloc_note = if allocs.is_empty() {
        Some("alloc_per_op: no -benchmem data".into())
    } else {
        Some(format!("alloc_per_op: mean {alloc_mean:.1} allocs/op across {} benches", allocs.len()))
    };
    let slope_pair = match worst {
        Some((g, s)) => (s, Some(format!("algo_complexity: worst slope {s:.3} from group '{g}'"))),
        None => (1.0, Some("algo_complexity: no scaling benches detected".into())),
    };
    (slope_pair.0, alloc_mean, slope_pair.1, alloc_note)
}

fn measure_go_db(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"\.Exec\s*\(",
        r"\.Query\s*\(",
        r"\.QueryRow\s*\(",
        r"\.NamedExec\s*\(",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let txn_re = Regex::new(r"db\.Begin\(\)|tx\.Commit\(\)|gorm\.Transaction").unwrap();
    let (count, txn) = super::node::scan_files(root, &["go"], &patterns, &txn_re);
    if count == 0 {
        return (0.0, Some("db_query_cost: no DB queries detected — metric omitted".into()));
    }
    let unbatched = count.saturating_sub(txn);
    (unbatched as f64, Some(format!("db_query_cost: {count} queries, {txn} txns, {unbatched} unbatched")))
}

fn measure_go_xproc(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"exec\.Command\s*\(",
        r"http\.\w+",
        r"net\.Dial\s*\(",
        r"rpc\.\w+",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let none = Regex::new(r"^$").unwrap();
    let (count, _) = super::node::scan_files(root, &["go"], &patterns, &none);
    if count == 0 {
        return (0.0, Some("xproc_roundtrips: no cross-process calls detected".into()));
    }
    (count as f64, Some(format!("xproc_roundtrips: {count} cross-process call sites")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn db_counts_go_calls() {
        let dir = tmpdir("perf-go-db");
        fs::write(
            dir.path().join("main.go"),
            "package main\nfunc x() { for _, u := range users { db.Exec(\"INSERT INTO users VALUES (?)\", u.ID) } }",
        ).unwrap();
        let (cost, _) = measure_go_db(dir.path());
        assert!(cost > 0.0);
    }

    #[test]
    fn xproc_counts_http() {
        let dir = tmpdir("perf-go-xproc");
        fs::write(
            dir.path().join("api.go"),
            "package main\nfunc x() { for _, u := range urls { http.Get(u) } }",
        ).unwrap();
        let (count, _) = measure_go_xproc(dir.path());
        assert!(count > 0.0);
    }

    fn tmpdir(prefix: &str) -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "{prefix}-{}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        TempDir { path }
    }
    struct TempDir { path: std::path::PathBuf }
    impl TempDir { fn path(&self) -> &std::path::Path { &self.path } }
    impl Drop for TempDir { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.path); } }
}
