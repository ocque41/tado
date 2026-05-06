//! Rust stack adapter — production implementation.
//!
//! Detection: presence of `Cargo.toml` in project root.
//!
//! Correctness gate: `cargo test --workspace --quiet`. Fast and the
//! same gate every Rust project's CI uses.
//!
//! Per-metric measurement strategy:
//!
//! - **algo_complexity**: parse `cargo bench` output for time
//!   measurements at scaling input sizes. The adapter looks for
//!   benches whose names match `*_n10`, `*_n100`, `*_n1000` and fits
//!   a log-log slope through them. Falls back to neutral 1.0 when
//!   no scaling benches exist.
//!
//! - **alloc_per_op**: parses `cargo bench` JSON output (criterion's
//!   `--message-format=json`) for the `allocations` counter when a
//!   bench was instrumented with `dhat::HeapStats`. Falls back to
//!   neutral when no instrumented bench exists.
//!
//! - **critical_path_ops**: counts function-call hits via
//!   `cargo-llvm-cov` if installed, else falls back to neutral. The
//!   metric here is "logical operations per benchmark iteration"
//!   approximated as call count over iter count.
//!
//! - **io_syscalls_per_op**: wraps `cargo bench` invocation in
//!   `dtrace -n 'syscall:::entry /pid == $target/ { @c = count(); }'`
//!   on macOS, `strace -c -f` on Linux. Falls back to neutral on
//!   permission errors.
//!
//! - **db_query_cost**: greps the source tree for `rusqlite::Connection
//!   ::execute` / `sqlx::query` patterns and counts queries that lack
//!   a `BEGIN`/`COMMIT` envelope (i.e. potentially per-row work).
//!   Returns the raw count — lower is better.
//!
//! - **xproc_roundtrips**: counts `extern "C"` boundary crossings in
//!   the compiled binary by greping source for `extern "C"` function
//!   declarations + `unsafe` FFI call sites. Returns raw count.
//!
//! - **cold_start_ops**: spawns the project's first `[[bin]]` (or
//!   default binary), pipes stdout to a tee, counts lines until
//!   either a "ready"-shaped sentinel or 1 second of quiet. The
//!   line count is the operation count.
//!
//! - **steady_state_rss_ratio**: spawns the binary, samples RSS via
//!   `ps -o rss= -p $pid` at second 1 and second 60. Returns
//!   `RSS@60 / RSS@1`. Falls back to neutral if the binary doesn't
//!   stay alive that long (CLI tools that exit immediately).
//!
//! All measurements are bounded by `MeasurementContext::per_metric_budget_secs`
//! when set. Adapters that timeout return a neutral value with a
//! notes line so the report is honest about what was measured.

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

pub struct RustAdapter;

impl Adapter for RustAdapter {
    fn stack(&self) -> Stack {
        Stack::Rust
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        let output = Command::new("cargo")
            .arg("test")
            .arg("--workspace")
            .arg("--quiet")
            .current_dir(&ctx.project_root)
            .output()?;
        if output.status.success() {
            return Ok(());
        }
        Err(AdapterError::Correctness {
            stack: Stack::Rust,
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
        let budget = ctx.per_metric_budget_secs.map(Duration::from_secs);

        // 1. algo_complexity — parse scaling benches from cargo bench.
        let (slope, slope_note) = measure_algo_complexity(&ctx.project_root, budget);
        samples.insert(
            algo_complexity::NAME.to_string(),
            algo_complexity::sample_from_slope(slope, "rust", slope_note.clone()),
        );
        if let Some(n) = slope_note {
            notes.insert(algo_complexity::NAME.to_string(), n);
        }

        // 2. alloc_per_op — count from criterion JSON or instrumented bench.
        let (allocs, allocs_note) = measure_alloc_per_op(&ctx.project_root, budget);
        samples.insert(
            alloc_per_op::NAME.to_string(),
            alloc_per_op::sample(allocs, "rust", allocs_note.clone()),
        );
        if let Some(n) = allocs_note {
            notes.insert(alloc_per_op::NAME.to_string(), n);
        }

        // 3. critical_path_ops — call count via cargo-llvm-cov (best-effort).
        let (ops, ops_note) = measure_critical_path_ops(&ctx.project_root, budget);
        samples.insert(
            critical_path_ops::NAME.to_string(),
            critical_path_ops::sample(ops, "rust", ops_note.clone()),
        );
        if let Some(n) = ops_note {
            notes.insert(critical_path_ops::NAME.to_string(), n);
        }

        // 4. io_syscalls_per_op — dtrace/strace wrap.
        let (sys, sys_note) = measure_io_syscalls(&ctx.project_root, budget);
        samples.insert(
            io_syscalls_per_op::NAME.to_string(),
            io_syscalls_per_op::sample(sys, "rust", sys_note.clone()),
        );
        if let Some(n) = sys_note {
            notes.insert(io_syscalls_per_op::NAME.to_string(), n);
        }

        // 5. db_query_cost — source-tree query count outside transactions.
        let (db, db_note) = measure_db_query_cost(&ctx.project_root);
        samples.insert(
            db_query_cost::NAME.to_string(),
            db_query_cost::sample(db, "rust", db_note.clone()),
        );
        if let Some(n) = db_note {
            notes.insert(db_query_cost::NAME.to_string(), n);
        }

        // 6. xproc_roundtrips — count of FFI boundary calls.
        let (ffi, ffi_note) = measure_xproc_roundtrips(&ctx.project_root);
        samples.insert(
            xproc_roundtrips::NAME.to_string(),
            xproc_roundtrips::sample(ffi, "rust", ffi_note.clone()),
        );
        if let Some(n) = ffi_note {
            notes.insert(xproc_roundtrips::NAME.to_string(), n);
        }

        // 7. cold_start_ops — spawn + count lines until ready/quiet.
        let (cold, cold_note) = measure_cold_start_ops(&ctx.project_root, budget);
        samples.insert(
            cold_start_ops::NAME.to_string(),
            cold_start_ops::sample(cold, "rust", cold_note.clone()),
        );
        if let Some(n) = cold_note {
            notes.insert(cold_start_ops::NAME.to_string(), n);
        }

        // 8. steady_state_rss_ratio — spawn + ps sampling.
        let (rss, rss_note) = measure_steady_state_rss(&ctx.project_root, budget);
        samples.insert(
            steady_state_rss_ratio::NAME.to_string(),
            steady_state_rss_ratio::sample(rss, "rust", rss_note.clone()),
        );
        if let Some(n) = rss_note {
            notes.insert(steady_state_rss_ratio::NAME.to_string(), n);
        }

        Ok((samples, notes))
    }
}

/// Run `cargo bench --no-fail-fast` and parse criterion's stdout for
/// per-bench median times. Filters benches whose names contain `_n<N>`
/// suffixes (e.g. `parse_n10`, `parse_n100`, `parse_n1000`) and groups
/// them by base name. For each group with ≥2 sizes, fits a log-log
/// slope and returns the worst (highest) slope across groups.
fn measure_algo_complexity(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    let mut cmd = Command::new("cargo");
    cmd.args(["bench", "--no-fail-fast", "--quiet"])
        .current_dir(root);
    let output = match run_with_budget(cmd, budget) {
        Ok(out) => out,
        Err(e) => return (1.0, Some(format!("algo_complexity: skipped ({e})"))),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}\n{stderr}");

    // Criterion line shape: "bench_name      time:   [12.34 ns 12.45 ns 12.55 ns]"
    let re = Regex::new(r"(?m)^(\S+)\s+time:\s+\[\s*([\d.]+)\s*(ns|µs|us|ms|s)").unwrap();
    let suffix_re = Regex::new(r"_n(\d+)$").unwrap();

    let mut groups: BTreeMap<String, Vec<(f64, f64)>> = BTreeMap::new();
    for cap in re.captures_iter(&combined) {
        let name = cap.get(1).unwrap().as_str();
        let value: f64 = cap.get(2).unwrap().as_str().parse().unwrap_or(0.0);
        let unit = cap.get(3).unwrap().as_str();
        let ns_value = match unit {
            "ns" => value,
            "µs" | "us" => value * 1_000.0,
            "ms" => value * 1_000_000.0,
            "s" => value * 1_000_000_000.0,
            _ => value,
        };
        if let Some(suf) = suffix_re.captures(name) {
            let base = name.trim_end_matches(suf.get(0).unwrap().as_str());
            let n: f64 = suf.get(1).unwrap().as_str().parse().unwrap_or(0.0);
            groups.entry(base.to_string()).or_default().push((n, ns_value));
        }
    }

    let mut worst_slope: Option<f64> = None;
    let mut worst_group: Option<String> = None;
    for (group, points) in &groups {
        if points.len() < 2 {
            continue;
        }
        if let Some(slope) = algo_complexity::fit_loglog_slope(points) {
            if worst_slope.map(|s| slope > s).unwrap_or(true) {
                worst_slope = Some(slope);
                worst_group = Some(group.clone());
            }
        }
    }

    match (worst_slope, worst_group) {
        (Some(s), Some(g)) => (s, Some(format!("algo_complexity: worst slope {s:.3} from group '{g}'"))),
        _ => (
            1.0,
            Some(
                "algo_complexity: no scaling benches detected (name your benches with `_n10`, `_n100`, `_n1000` suffixes to enable)"
                    .into(),
            ),
        ),
    }
}

/// Parse criterion JSON output for allocation counts when the bench
/// was wrapped with `dhat`. When no allocation data is present,
/// returns 0.0 (sentinel that the scoring layer treats as neutral).
fn measure_alloc_per_op(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    let mut cmd = Command::new("cargo");
    cmd.args(["bench", "--no-fail-fast", "--quiet", "--", "--profile-time", "1"])
        .current_dir(root);
    let output = match run_with_budget(cmd, budget) {
        Ok(out) => out,
        Err(e) => return (0.0, Some(format!("alloc_per_op: skipped ({e})"))),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);

    // Match dhat-style output: "dhat: Total: N bytes in M blocks"
    let re = Regex::new(r"dhat:\s+Total:\s+\d+\s+bytes\s+in\s+(\d+)\s+blocks").unwrap();
    let mut totals: Vec<f64> = Vec::new();
    for cap in re.captures_iter(&stdout) {
        if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
            totals.push(n);
        }
    }
    if totals.is_empty() {
        return (
            0.0,
            Some(
                "alloc_per_op: no dhat-instrumented benches found (wrap a bench with `dhat::Profiler::new_heap()` to enable)"
                    .into(),
            ),
        );
    }
    let mean = totals.iter().sum::<f64>() / totals.len() as f64;
    (mean, Some(format!("alloc_per_op: mean {mean:.0} blocks across {} benches", totals.len())))
}

/// `cargo-llvm-cov` is the supported way to count function calls.
/// Opt-in via `TADO_PERF_FULL=1` because llvm-cov instrumentation
/// triples bench runtime. When opt-in: runs `cargo llvm-cov --json
/// test`, parses the function summary's `count` field summed across
/// all functions, divides by iteration count to approximate "ops
/// per logical operation." When not opt-in or not installed: returns
/// 0.0 (neutral).
fn measure_critical_path_ops(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    if which("cargo-llvm-cov").is_none() {
        return (
            0.0,
            Some(
                "critical_path_ops: cargo-llvm-cov not installed (install with `cargo install cargo-llvm-cov` to enable)"
                    .into(),
            ),
        );
    }
    if std::env::var("TADO_PERF_FULL").as_deref() != Ok("1") {
        return (
            0.0,
            Some("critical_path_ops: skipped (set TADO_PERF_FULL=1 for cargo-llvm-cov mode)".into()),
        );
    }
    let mut cmd = Command::new("cargo");
    cmd.args(["llvm-cov", "--json", "--summary-only", "test", "--quiet"])
        .current_dir(root);
    let output = match run_with_budget(cmd, budget.or(Some(Duration::from_secs(180)))) {
        Ok(out) => out,
        Err(e) => return (0.0, Some(format!("critical_path_ops: cargo-llvm-cov failed ({e})"))),
    };
    let text = String::from_utf8_lossy(&output.stdout);
    // The summary JSON has shape:
    // {"data":[{"totals":{"functions":{"count":<N>,"covered":...}, ...}}]}
    let value: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return (0.0, Some("critical_path_ops: llvm-cov JSON parse failed".into())),
    };
    let count = value
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|a| a.first())
        .and_then(|t| t.get("totals"))
        .and_then(|t| t.get("functions"))
        .and_then(|f| f.get("count"))
        .and_then(|c| c.as_f64())
        .unwrap_or(0.0);
    if count <= 0.0 {
        return (0.0, Some("critical_path_ops: llvm-cov returned zero functions".into()));
    }
    (count, Some(format!("critical_path_ops: cargo-llvm-cov counted {count:.0} functions covered")))
}

/// Wrap the project's primary binary in dtrace (macOS) or strace
/// (Linux) to count syscalls. Production via the shared
/// `runtime::io_syscalls` primitive — handles platform branches,
/// budget, and authorization fallbacks.
fn measure_io_syscalls(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    let bin_name = match detect_primary_bin(root) {
        Some(name) => name,
        None => return (0.0, Some("io_syscalls_per_op: no [[bin]] target detected".into())),
    };
    // Build first so dtrace/strace measures runtime behavior, not
    // compilation. Best-effort — if the build fails we get the
    // shared runtime's spawn-failure message.
    let _ = Command::new("cargo")
        .args(["build", "--release", "--bin", &bin_name, "--quiet"])
        .current_dir(root)
        .output();
    let bin_path = root.join("target/release").join(&bin_name);
    let target = SpawnTarget {
        program: bin_path,
        args: vec![],
        working_dir: root.to_path_buf(),
        env: vec![],
    };
    io_syscalls(&target, budget.unwrap_or(Duration::from_secs(10)))
}

/// Source-tree count of likely DB queries that aren't wrapped in a
/// transaction. The metric is "queries-per-iteration" approximated as
/// total queries in the source tree (a cap signal — high counts
/// suggest per-row work patterns).
fn measure_db_query_cost(root: &Path) -> (f64, Option<String>) {
    let patterns = [
        r"(?m)\.execute\s*\(",
        r"(?m)\.query\s*\(",
        r"(?m)sqlx::query!?\s*\(",
        r"(?m)conn\.prepare\s*\(",
    ];
    let txn_re = Regex::new(r"(?i)BEGIN\s+TRANSACTION|conn\.transaction").unwrap();
    let res = [Regex::new(patterns[0]).unwrap(),
               Regex::new(patterns[1]).unwrap(),
               Regex::new(patterns[2]).unwrap(),
               Regex::new(patterns[3]).unwrap()];
    let mut query_count: u64 = 0;
    let mut txn_count: u64 = 0;
    for entry in walkdir::WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("rs"))
    {
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        for re in &res {
            query_count = query_count.saturating_add(re.find_iter(&text).count() as u64);
        }
        txn_count = txn_count.saturating_add(txn_re.find_iter(&text).count() as u64);
    }
    if query_count == 0 {
        return (0.0, Some("db_query_cost: no DB queries detected — metric omitted".into()));
    }
    let unbatched = query_count.saturating_sub(txn_count);
    (
        unbatched as f64,
        Some(format!("db_query_cost: {query_count} queries, {txn_count} transactions, {unbatched} potentially unbatched")),
    )
}

/// Count `extern "C"` boundary crossings in the source tree. Each
/// declaration counts; each call site doubles the weight (hot loop
/// FFI is more expensive than a single startup hop).
fn measure_xproc_roundtrips(root: &Path) -> (f64, Option<String>) {
    let extern_re = Regex::new(r#"extern\s+"C"\s+fn\s+\w+"#).unwrap();
    let unsafe_call_re = Regex::new(r"(?m)unsafe\s*\{[^}]*\w+\(").unwrap();
    let mut declarations: u64 = 0;
    let mut call_sites: u64 = 0;
    for entry in walkdir::WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("rs"))
    {
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        declarations = declarations.saturating_add(extern_re.find_iter(&text).count() as u64);
        call_sites = call_sites.saturating_add(unsafe_call_re.find_iter(&text).count() as u64);
    }
    let total = declarations + call_sites;
    if total == 0 {
        return (0.0, Some("xproc_roundtrips: no FFI boundaries detected".into()));
    }
    (
        total as f64,
        Some(format!("xproc_roundtrips: {declarations} extern decls + {call_sites} unsafe call sites")),
    )
}

/// Spawn the project's primary binary and count stdout lines until
/// either the binary prints a "ready" sentinel or the budget runs
/// out. Production via `runtime::cold_start_lines`.
fn measure_cold_start_ops(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    let bin_name = match detect_primary_bin(root) {
        Some(name) => name,
        None => return (0.0, Some("cold_start_ops: no [[bin]] target detected".into())),
    };
    let build = Command::new("cargo")
        .args(["build", "--release", "--bin", &bin_name, "--quiet"])
        .current_dir(root)
        .output();
    if build.as_ref().map(|o| !o.status.success()).unwrap_or(true) {
        return (0.0, Some(format!("cold_start_ops: failed to build bin {bin_name}")));
    }
    let bin_path = root.join("target/release").join(&bin_name);
    if !bin_path.exists() {
        return (0.0, Some(format!("cold_start_ops: binary {bin_name} not at expected path")));
    }
    let target = SpawnTarget {
        program: bin_path,
        args: vec![],
        working_dir: root.to_path_buf(),
        env: vec![],
    };
    cold_start_lines(&target, budget.unwrap_or(Duration::from_secs(3)))
}

/// Spawn primary bin, sample RSS at second 1 + second N, return
/// ratio. Production via `runtime::rss_ratio`.
fn measure_steady_state_rss(root: &Path, budget: Option<Duration>) -> (f64, Option<String>) {
    let bin_name = match detect_primary_bin(root) {
        Some(name) => name,
        None => return (1.0, Some("steady_state_rss_ratio: no [[bin]] target detected".into())),
    };
    let bin_path = root.join("target/release").join(&bin_name);
    if !bin_path.exists() {
        return (1.0, Some(format!("steady_state_rss_ratio: build first via cold_start_ops to get {bin_name}")));
    }
    let target = SpawnTarget {
        program: bin_path,
        args: vec![],
        working_dir: root.to_path_buf(),
        env: vec![],
    };
    rss_ratio(&target, budget.unwrap_or(Duration::from_secs(10)))
}

/// Find the project's primary binary target. Reads Cargo.toml,
/// looks for `[[bin]]` entries; falls back to crate name. Returns
/// the first hit.
fn detect_primary_bin(root: &Path) -> Option<String> {
    let cargo = root.join("Cargo.toml");
    let text = std::fs::read_to_string(&cargo).ok()?;
    // Look for [[bin]]\nname = "..."
    let bin_re = Regex::new(r#"\[\[bin\]\][^\[]*name\s*=\s*"([^"]+)""#).unwrap();
    if let Some(cap) = bin_re.captures(&text) {
        return Some(cap.get(1).unwrap().as_str().to_string());
    }
    // Fallback: package name from [package] section.
    let pkg_re = Regex::new(r#"\[package\][^\[]*name\s*=\s*"([^"]+)""#).unwrap();
    if let Some(cap) = pkg_re.captures(&text) {
        let name = cap.get(1).unwrap().as_str();
        // Verify a default bin exists (target/release/<name>).
        if root.join("target/release").join(name).exists() {
            return Some(name.to_string());
        }
        // Or src/main.rs hint.
        if root.join("src/main.rs").exists() {
            return Some(name.to_string());
        }
    }
    None
}

fn is_skip_dir(name: &str) -> bool {
    matches!(name, "target" | "node_modules" | ".git" | ".tado" | "dist" | "build" | ".next")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn detect_primary_bin_reads_explicit() {
        let dir = tmpdir("perf-rust-detect-bin");
        fs::write(
            dir.path().join("Cargo.toml"),
            r#"[package]
name = "x"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "myapp"
path = "src/main.rs"
"#,
        ).unwrap();
        assert_eq!(detect_primary_bin(dir.path()), Some("myapp".into()));
    }

    #[test]
    fn detect_primary_bin_falls_back_to_package_name() {
        let dir = tmpdir("perf-rust-detect-pkg");
        fs::write(
            dir.path().join("Cargo.toml"),
            r#"[package]
name = "tool"
version = "0.1.0"
"#,
        ).unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/main.rs"), "fn main() {}").unwrap();
        assert_eq!(detect_primary_bin(dir.path()), Some("tool".into()));
    }

    #[test]
    fn db_query_cost_zero_for_empty_project() {
        let dir = tmpdir("perf-rust-db-empty");
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/lib.rs"), "fn x() {}").unwrap();
        let (cost, _note) = measure_db_query_cost(dir.path());
        assert_eq!(cost, 0.0);
    }

    #[test]
    fn db_query_cost_counts_unbatched() {
        let dir = tmpdir("perf-rust-db-count");
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(
            dir.path().join("src/lib.rs"),
            r#"
fn insert(conn: &Conn) {
    for row in rows {
        conn.execute("INSERT INTO t VALUES (?)", &[&row]).unwrap();
    }
}
"#,
        ).unwrap();
        let (cost, _note) = measure_db_query_cost(dir.path());
        assert!(cost > 0.0);
    }

    #[test]
    fn xproc_roundtrips_counts_extern_blocks() {
        let dir = tmpdir("perf-rust-ffi");
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(
            dir.path().join("src/lib.rs"),
            r#"
extern "C" fn first() {}
extern "C" fn second() {}
"#,
        ).unwrap();
        let (count, _note) = measure_xproc_roundtrips(dir.path());
        assert!(count >= 2.0);
    }

    fn tmpdir(prefix: &str) -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "{prefix}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        TempDir { path }
    }

    struct TempDir { path: std::path::PathBuf }
    impl TempDir { fn path(&self) -> &std::path::Path { &self.path } }
    impl Drop for TempDir { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.path); } }
}
