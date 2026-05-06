//! Python stack adapter — production implementation.
//!
//! Detection: `pyproject.toml` or `setup.py` in project root.
//!
//! Correctness gate: `pytest` (preferred) or skip if not installed.
//!
//! Per-metric measurement:
//! - **algo_complexity**: parses `pytest --benchmark-only
//!   --benchmark-json=...` output for benches grouped by `_n<N>`.
//! - **alloc_per_op**: parses `tracemalloc` peak when bench wraps it;
//!   else neutral.
//! - **critical_path_ops**: parses cProfile cumulative call count when
//!   `--profile` flag set; else neutral.
//! - **io_syscalls_per_op**: dtrace/strace wrap, opt-in.
//! - **db_query_cost**: counts `cursor.execute` / `session.query` /
//!   `db.session.add` patterns; subtracts patterns inside `with
//!   db.transaction():` blocks.
//! - **xproc_roundtrips**: counts `subprocess.run/Popen`, `requests.*`,
//!   `httpx.*`, `urllib.*` patterns.
//! - **cold_start_ops**: spawn entry script, count stdout lines.
//! - **steady_state_rss_ratio**: ps-sampling on the spawned python
//!   process.

use super::{Adapter, AdapterError, Stack};
use crate::metrics::{
    algo_complexity, alloc_per_op, cold_start_ops, critical_path_ops, db_query_cost,
    io_syscalls_per_op, steady_state_rss_ratio, xproc_roundtrips, MetricSample,
};
use crate::runtime::{cold_start_lines, io_syscalls, rss_ratio, run_with_budget, SpawnTarget};
use crate::MeasurementContext;
use regex::Regex;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub struct PythonAdapter;

impl Adapter for PythonAdapter {
    fn stack(&self) -> Stack {
        Stack::Python
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        let output = Command::new("pytest")
            .current_dir(&ctx.project_root)
            .output();
        match output {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => Err(AdapterError::Correctness {
                stack: Stack::Python,
                exit_code: out.status.code().unwrap_or(-1),
                stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            }),
            Err(_) => Ok(()),
        }
    }

    fn measure(
        &self,
        ctx: &MeasurementContext,
    ) -> Result<(BTreeMap<String, MetricSample>, BTreeMap<String, String>), AdapterError> {
        let mut samples = BTreeMap::new();
        let mut notes = BTreeMap::new();

        let (slope, slope_note) = measure_python_algo(&ctx.project_root, &ctx.run_dir);
        samples.insert(
            algo_complexity::NAME.to_string(),
            algo_complexity::sample_from_slope(slope, "python", slope_note.clone()),
        );
        if let Some(n) = slope_note { notes.insert(algo_complexity::NAME.to_string(), n); }

        let (allocs, allocs_note) = measure_python_alloc(&ctx.project_root, &ctx.run_dir);
        samples.insert(alloc_per_op::NAME.to_string(), alloc_per_op::sample(allocs, "python", allocs_note.clone()));
        if let Some(n) = allocs_note { notes.insert(alloc_per_op::NAME.to_string(), n); }

        let (cp, cp_note) = measure_python_critical_path(&ctx.project_root, &ctx.run_dir);
        samples.insert(critical_path_ops::NAME.to_string(), critical_path_ops::sample(cp, "python", cp_note.clone()));
        if let Some(n) = cp_note { notes.insert(critical_path_ops::NAME.to_string(), n); }

        let (sys, sys_note) = measure_python_io_syscalls(&ctx.project_root);
        samples.insert(io_syscalls_per_op::NAME.to_string(), io_syscalls_per_op::sample(sys, "python", sys_note.clone()));
        if let Some(n) = sys_note { notes.insert(io_syscalls_per_op::NAME.to_string(), n); }

        let (db, db_note) = measure_python_db(&ctx.project_root);
        samples.insert(db_query_cost::NAME.to_string(), db_query_cost::sample(db, "python", db_note.clone()));
        if let Some(n) = db_note { notes.insert(db_query_cost::NAME.to_string(), n); }

        let (xp, xp_note) = measure_python_xproc(&ctx.project_root);
        samples.insert(xproc_roundtrips::NAME.to_string(), xproc_roundtrips::sample(xp, "python", xp_note.clone()));
        if let Some(n) = xp_note { notes.insert(xproc_roundtrips::NAME.to_string(), n); }

        let (cold, cold_note) = measure_python_cold_start(&ctx.project_root);
        samples.insert(cold_start_ops::NAME.to_string(), cold_start_ops::sample(cold, "python", cold_note.clone()));
        if let Some(n) = cold_note { notes.insert(cold_start_ops::NAME.to_string(), n); }

        let (rss, rss_note) = measure_python_rss(&ctx.project_root);
        samples.insert(steady_state_rss_ratio::NAME.to_string(), steady_state_rss_ratio::sample(rss, "python", rss_note.clone()));
        if let Some(n) = rss_note { notes.insert(steady_state_rss_ratio::NAME.to_string(), n); }

        Ok((samples, notes))
    }
}

/// Wrap the entry script in a tracemalloc shim that prints
/// `PERF_TRACEMALLOC_PEAK=<bytes>` on exit. Returns the peak heap
/// size as the alloc proxy.
fn measure_python_alloc(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    let entry = match detect_python_entry(root) {
        Some(e) => e,
        None => return (0.0, Some("alloc_per_op: no entry script (looked for main.py / app.py / __main__.py)".into())),
    };
    let shim = run_dir.join("perf-tracemalloc-shim.py");
    let _ = std::fs::create_dir_all(run_dir);
    let shim_src = format!(r#"
import tracemalloc, runpy, sys
tracemalloc.start()
try:
    runpy.run_path({entry:?}, run_name="__main__")
except SystemExit:
    pass
except BaseException as e:
    sys.stderr.write(f"perf-shim: target raised {{e!r}}\n")
peak = tracemalloc.get_traced_memory()[1]
print(f"PERF_TRACEMALLOC_PEAK={{peak}}")
"#, entry = entry.display().to_string());
    if std::fs::write(&shim, shim_src).is_err() {
        return (0.0, Some("alloc_per_op: failed to write tracemalloc shim".into()));
    }
    let mut cmd = Command::new("python3");
    cmd.arg(&shim).current_dir(root);
    let output = match run_with_budget(cmd, Some(Duration::from_secs(20))) {
        Ok(out) => out,
        Err(e) => return (0.0, Some(format!("alloc_per_op: tracemalloc shim failed ({e})"))),
    };
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let re = Regex::new(r"PERF_TRACEMALLOC_PEAK=(\d+)").unwrap();
    if let Some(cap) = re.captures(&combined) {
        if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
            return (n, Some(format!("alloc_per_op: tracemalloc peak {n:.0} bytes")));
        }
    }
    (0.0, Some("alloc_per_op: tracemalloc shim produced no peak line".into()))
}

/// Wrap entry in a cProfile shim that prints
/// `PERF_CPROFILE_NCALLS=<int>`.
fn measure_python_critical_path(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    let entry = match detect_python_entry(root) {
        Some(e) => e,
        None => return (0.0, Some("critical_path_ops: no entry script".into())),
    };
    let shim = run_dir.join("perf-cprofile-shim.py");
    let _ = std::fs::create_dir_all(run_dir);
    let shim_src = format!(r#"
import cProfile, pstats, runpy, io, sys
pr = cProfile.Profile()
pr.enable()
try:
    runpy.run_path({entry:?}, run_name="__main__")
except SystemExit:
    pass
except BaseException as e:
    sys.stderr.write(f"perf-shim: target raised {{e!r}}\n")
pr.disable()
s = io.StringIO()
pstats.Stats(pr, stream=s).strip_dirs().sort_stats("cumulative").print_stats()
text = s.getvalue()
import re
m = re.search(r"(\d+)\s+function\s+calls", text)
ncalls = int(m.group(1)) if m else 0
print(f"PERF_CPROFILE_NCALLS={{ncalls}}")
"#, entry = entry.display().to_string());
    if std::fs::write(&shim, shim_src).is_err() {
        return (0.0, Some("critical_path_ops: failed to write cProfile shim".into()));
    }
    let mut cmd = Command::new("python3");
    cmd.arg(&shim).current_dir(root);
    let output = match run_with_budget(cmd, Some(Duration::from_secs(20))) {
        Ok(out) => out,
        Err(e) => return (0.0, Some(format!("critical_path_ops: cProfile shim failed ({e})"))),
    };
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let re = Regex::new(r"PERF_CPROFILE_NCALLS=(\d+)").unwrap();
    if let Some(cap) = re.captures(&combined) {
        if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
            return (n, Some(format!("critical_path_ops: cProfile counted {n:.0} function calls")));
        }
    }
    (0.0, Some("critical_path_ops: cProfile shim produced no count line".into()))
}

fn measure_python_io_syscalls(root: &Path) -> (f64, Option<String>) {
    let target = match python_target(root) {
        Some(t) => t,
        None => return (0.0, Some("io_syscalls_per_op: no entry script".into())),
    };
    io_syscalls(&target, Duration::from_secs(10))
}

fn measure_python_cold_start(root: &Path) -> (f64, Option<String>) {
    let target = match python_target(root) {
        Some(t) => t,
        None => return (0.0, Some("cold_start_ops: no entry script".into())),
    };
    cold_start_lines(&target, Duration::from_secs(10))
}

fn measure_python_rss(root: &Path) -> (f64, Option<String>) {
    let target = match python_target(root) {
        Some(t) => t,
        None => return (1.0, Some("steady_state_rss_ratio: no entry script".into())),
    };
    rss_ratio(&target, Duration::from_secs(10))
}

fn detect_python_entry(root: &Path) -> Option<PathBuf> {
    for cand in ["main.py", "app.py", "__main__.py", "src/main.py"] {
        let p = root.join(cand);
        if p.exists() { return Some(p); }
    }
    None
}

fn python_target(root: &Path) -> Option<SpawnTarget> {
    let entry = detect_python_entry(root)?;
    Some(SpawnTarget {
        program: PathBuf::from("python3"),
        args: vec![entry.display().to_string()],
        working_dir: root.to_path_buf(),
        env: vec![],
    })
}

fn measure_python_algo(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    let json_out = run_dir.join("pytest-bench.json");
    let _ = std::fs::create_dir_all(run_dir);
    let output = Command::new("pytest")
        .args([
            "--benchmark-only",
            "--benchmark-disable-gc",
            "-q",
            &format!("--benchmark-json={}", json_out.display()),
        ])
        .current_dir(root)
        .output();
    let Ok(_) = output else {
        return (1.0, Some("algo_complexity: pytest-benchmark not installed".into()));
    };
    let Ok(text) = std::fs::read_to_string(&json_out) else {
        return (1.0, Some("algo_complexity: no pytest-benchmark output produced".into()));
    };
    // The benchmark JSON shape: {"benchmarks": [{"name": "test_x_n100",
    // "stats": {"mean": 0.001, ...}}, ...]}
    let value: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return (1.0, Some("algo_complexity: pytest-benchmark JSON parse failed".into())),
    };
    let suffix_re = Regex::new(r"_n(\d+)$").unwrap();
    let mut groups: BTreeMap<String, Vec<(f64, f64)>> = BTreeMap::new();
    if let Some(arr) = value.get("benchmarks").and_then(|v| v.as_array()) {
        for b in arr {
            let Some(name) = b.get("name").and_then(|v| v.as_str()) else { continue };
            let Some(stats) = b.get("stats").and_then(|v| v.as_object()) else { continue };
            let Some(mean) = stats.get("mean").and_then(|v| v.as_f64()) else { continue };
            if let Some(suf) = suffix_re.captures(name) {
                let base = name.trim_end_matches(suf.get(0).unwrap().as_str());
                let n: f64 = suf.get(1).unwrap().as_str().parse().unwrap_or(0.0);
                groups.entry(base.to_string()).or_default().push((n, mean * 1_000_000.0));
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
    match worst {
        Some((g, s)) => (s, Some(format!("algo_complexity: worst slope {s:.3} from group '{g}'"))),
        None => (1.0, Some("algo_complexity: no scaling benches detected".into())),
    }
}

fn measure_python_db(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"\.execute\s*\(",
        r"\.query\s*\(",
        r"session\.add\s*\(",
        r"session\.commit\s*\(",
        r"cursor\.executemany\s*\(",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let txn_re = Regex::new(r"\bbegin\(\)|with\s+db\.transaction|@db\.atomic").unwrap();
    let (count, txn) = super::node::scan_files(root, &["py"], &patterns, &txn_re);
    if count == 0 {
        return (0.0, Some("db_query_cost: no DB queries detected — metric omitted".into()));
    }
    let unbatched = count.saturating_sub(txn);
    (unbatched as f64, Some(format!("db_query_cost: {count} queries, {txn} txns, {unbatched} unbatched")))
}

fn measure_python_xproc(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"subprocess\.\w+",
        r"requests\.\w+",
        r"httpx\.\w+",
        r"urllib\.\w+\.urlopen",
        r"multiprocessing\.\w+",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let none = Regex::new(r"^$").unwrap();
    let (count, _) = super::node::scan_files(root, &["py"], &patterns, &none);
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
    fn db_counts_orm_calls() {
        let dir = tmpdir("perf-py-db");
        fs::write(
            dir.path().join("app.py"),
            "for u in users:\n    session.add(u)\nsession.commit()\n",
        ).unwrap();
        let (cost, _) = measure_python_db(dir.path());
        assert!(cost > 0.0);
    }

    #[test]
    fn xproc_counts_subprocess() {
        let dir = tmpdir("perf-py-xproc");
        fs::write(
            dir.path().join("app.py"),
            "for url in urls:\n    requests.get(url)\n    subprocess.run(['ls'])\n",
        ).unwrap();
        let (count, _) = measure_python_xproc(dir.path());
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
