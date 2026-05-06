//! Swift stack adapter — production implementation.
//!
//! Detection: `Package.swift` or `*.xcodeproj` / `*.xcworkspace`.
//!
//! Correctness gate: `swift test`. Skipped for Xcode-only projects
//! (operator should run xcodebuild manually).
//!
//! Per-metric measurement:
//! - **algo_complexity**: parses `swift test --filter '*Bench*'`
//!   output for `.measure { ... }` block timings. Groups by name
//!   suffix (`_n10`, `_n100`, `_n1000`) and fits log-log slope.
//! - **alloc_per_op**: parses Instruments `xctrace` Allocations
//!   template output when available; else neutral.
//! - **critical_path_ops**: skipped (Instruments-only, blow-up budget).
//! - **io_syscalls_per_op**: dtrace wrap on macOS only; opt-in via
//!   `TADO_PERF_DTRACE=1`.
//! - **db_query_cost**: source-tree count of `sqlite3_exec` /
//!   `Connection.execute` / Core Data fetch patterns.
//! - **xproc_roundtrips**: count of `@_silgen_name` / `import C`
//!   declarations + Objective-C bridge call sites.
//! - **cold_start_ops**: spawn `swift run` and count stdout lines
//!   until ready-shaped sentinel.
//! - **steady_state_rss_ratio**: same ps-sampling protocol as Rust.

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

pub struct SwiftAdapter;

impl Adapter for SwiftAdapter {
    fn stack(&self) -> Stack {
        Stack::Swift
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        // Only run swift test if Package.swift exists. Xcode-only
        // projects need xcodebuild which we don't auto-invoke.
        if !ctx.project_root.join("Package.swift").exists() {
            return Ok(());
        }
        let output = Command::new("swift")
            .arg("test")
            .current_dir(&ctx.project_root)
            .output()?;
        if output.status.success() {
            return Ok(());
        }
        Err(AdapterError::Correctness {
            stack: Stack::Swift,
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

        let (slope, slope_note) = measure_swift_algo_complexity(&ctx.project_root);
        samples.insert(
            algo_complexity::NAME.to_string(),
            algo_complexity::sample_from_slope(slope, "swift", slope_note.clone()),
        );
        if let Some(n) = slope_note {
            notes.insert(algo_complexity::NAME.to_string(), n);
        }

        let (allocs, allocs_note) = measure_swift_alloc(&ctx.project_root);
        samples.insert(alloc_per_op::NAME.to_string(), alloc_per_op::sample(allocs, "swift", allocs_note.clone()));
        if let Some(n) = allocs_note { notes.insert(alloc_per_op::NAME.to_string(), n); }

        let (cp, cp_note) = measure_swift_critical_path(&ctx.project_root);
        samples.insert(critical_path_ops::NAME.to_string(), critical_path_ops::sample(cp, "swift", cp_note.clone()));
        if let Some(n) = cp_note { notes.insert(critical_path_ops::NAME.to_string(), n); }

        let (sys, sys_note) = measure_swift_io_syscalls(&ctx.project_root);
        samples.insert(io_syscalls_per_op::NAME.to_string(), io_syscalls_per_op::sample(sys, "swift", sys_note.clone()));
        if let Some(n) = sys_note { notes.insert(io_syscalls_per_op::NAME.to_string(), n); }

        let (db, db_note) = measure_swift_db_query_cost(&ctx.project_root);
        samples.insert(db_query_cost::NAME.to_string(), db_query_cost::sample(db, "swift", db_note.clone()));
        if let Some(n) = db_note { notes.insert(db_query_cost::NAME.to_string(), n); }

        let (ffi, ffi_note) = measure_swift_xproc(&ctx.project_root);
        samples.insert(xproc_roundtrips::NAME.to_string(), xproc_roundtrips::sample(ffi, "swift", ffi_note.clone()));
        if let Some(n) = ffi_note { notes.insert(xproc_roundtrips::NAME.to_string(), n); }

        let (cold, cold_note) = measure_swift_cold_start(&ctx.project_root);
        samples.insert(cold_start_ops::NAME.to_string(), cold_start_ops::sample(cold, "swift", cold_note.clone()));
        if let Some(n) = cold_note { notes.insert(cold_start_ops::NAME.to_string(), n); }

        let (rss, rss_note) = measure_swift_rss(&ctx.project_root);
        samples.insert(steady_state_rss_ratio::NAME.to_string(), steady_state_rss_ratio::sample(rss, "swift", rss_note.clone()));
        if let Some(n) = rss_note { notes.insert(steady_state_rss_ratio::NAME.to_string(), n); }

        Ok((samples, notes))
    }
}

/// Use Instruments `xctrace` Allocations template to count
/// allocations during a `swift test --filter '*Bench*'` run. Opt-in
/// via `TADO_PERF_INSTRUMENTS=1` because xctrace runs sequentially
/// and is slow (~30s startup).
fn measure_swift_alloc(root: &Path) -> (f64, Option<String>) {
    if std::env::var("TADO_PERF_INSTRUMENTS").as_deref() != Ok("1") {
        return (0.0, Some("alloc_per_op: Instruments mode opt-in (set TADO_PERF_INSTRUMENTS=1)".into()));
    }
    if which("xctrace").is_none() {
        return (0.0, Some("alloc_per_op: xctrace not installed (Xcode required)".into()));
    }
    let trace_dir = std::env::temp_dir().join(format!(
        "perf-suite-xctrace-{}.trace",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mut cmd = Command::new("xctrace");
    cmd.args([
        "record",
        "--template", "Allocations",
        "--launch", "--",
        "swift", "test", "--filter", "Bench",
    ])
        .arg("--output").arg(&trace_dir)
        .current_dir(root);
    let output = run_with_budget(cmd, Some(Duration::from_secs(60)));
    let _ = std::fs::remove_dir_all(&trace_dir);
    match output {
        Ok(out) => {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            let re = Regex::new(r"Total\s+Allocations:\s+(\d+)").unwrap();
            if let Some(cap) = re.captures(&combined) {
                if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
                    return (n, Some(format!("alloc_per_op: xctrace counted {n:.0} allocations")));
                }
            }
            (0.0, Some("alloc_per_op: xctrace produced no Total Allocations line".into()))
        }
        Err(e) => (0.0, Some(format!("alloc_per_op: xctrace failed ({e})"))),
    }
}

/// Use `xctrace record --template "Time Profiler"` to count samples
/// across the bench run. Returns sample count as the
/// critical-path-ops approximation. Opt-in via TADO_PERF_INSTRUMENTS=1.
fn measure_swift_critical_path(root: &Path) -> (f64, Option<String>) {
    if std::env::var("TADO_PERF_INSTRUMENTS").as_deref() != Ok("1") {
        return (0.0, Some("critical_path_ops: Instruments mode opt-in".into()));
    }
    if which("xctrace").is_none() {
        return (0.0, Some("critical_path_ops: xctrace not installed".into()));
    }
    let trace_dir = std::env::temp_dir().join(format!(
        "perf-suite-xctrace-tp-{}.trace",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mut cmd = Command::new("xctrace");
    cmd.args([
        "record",
        "--template", "Time Profiler",
        "--launch", "--",
        "swift", "test", "--filter", "Bench",
    ])
        .arg("--output").arg(&trace_dir)
        .current_dir(root);
    let output = run_with_budget(cmd, Some(Duration::from_secs(60)));
    let _ = std::fs::remove_dir_all(&trace_dir);
    match output {
        Ok(out) => {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            let re = Regex::new(r"(?i)samples:\s+(\d+)").unwrap();
            if let Some(cap) = re.captures(&combined) {
                if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
                    return (n, Some(format!("critical_path_ops: Time Profiler captured {n:.0} samples")));
                }
            }
            (0.0, Some("critical_path_ops: xctrace produced no sample count".into()))
        }
        Err(e) => (0.0, Some(format!("critical_path_ops: xctrace failed ({e})"))),
    }
}

fn measure_swift_io_syscalls(root: &Path) -> (f64, Option<String>) {
    let target = match swift_executable_target(root) {
        Some(t) => t,
        None => return (0.0, Some("io_syscalls_per_op: no swift executable target detected".into())),
    };
    io_syscalls(&target, Duration::from_secs(10))
}

fn measure_swift_cold_start(root: &Path) -> (f64, Option<String>) {
    let target = match swift_executable_target(root) {
        Some(t) => t,
        None => return (0.0, Some("cold_start_ops: no swift executable target detected".into())),
    };
    cold_start_lines(&target, Duration::from_secs(10))
}

fn measure_swift_rss(root: &Path) -> (f64, Option<String>) {
    let target = match swift_executable_target(root) {
        Some(t) => t,
        None => return (1.0, Some("steady_state_rss_ratio: no swift executable target detected".into())),
    };
    rss_ratio(&target, Duration::from_secs(10))
}

/// Detect the project's executable target and build it. Returns the
/// SpawnTarget pointing at the compiled binary, or None when there's
/// no executable (library-only Swift packages).
fn swift_executable_target(root: &Path) -> Option<SpawnTarget> {
    if !root.join("Package.swift").exists() {
        return None;
    }
    // `swift build --release --show-bin-path` prints the .build/release dir.
    let bin_path_out = Command::new("swift")
        .args(["build", "-c", "release", "--show-bin-path"])
        .current_dir(root)
        .output()
        .ok()?;
    if !bin_path_out.status.success() {
        return None;
    }
    let bin_dir = String::from_utf8_lossy(&bin_path_out.stdout).trim().to_string();
    if bin_dir.is_empty() {
        return None;
    }
    // Build first.
    let _ = Command::new("swift")
        .args(["build", "-c", "release"])
        .current_dir(root)
        .output();
    // Find the first executable in the bin dir that doesn't end in
    // .swiftmodule / .o / .dSYM.
    let dir = std::path::PathBuf::from(&bin_dir);
    let entries = std::fs::read_dir(&dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else { continue };
        if name.ends_with(".swiftmodule") || name.ends_with(".o") || name.ends_with(".dSYM") || name.ends_with(".d") {
            continue;
        }
        let metadata = entry.metadata().ok()?;
        if !metadata.is_file() {
            continue;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o111 == 0 {
                continue;
            }
        }
        return Some(SpawnTarget {
            program: path,
            args: vec![],
            working_dir: root.to_path_buf(),
            env: vec![],
        });
    }
    None
}

/// Run `swift test --filter '*Bench*'` and parse XCTest output for
/// `.measure { }` timings. XCTest prints lines of shape:
///   `/path/to/test:line: Test Case '-[Class testFoo_n100]' measured ...`
/// or `Time:           0.001 sec ±0.0001`
fn measure_swift_algo_complexity(root: &Path) -> (f64, Option<String>) {
    if !root.join("Package.swift").exists() {
        return (1.0, Some("algo_complexity: Package.swift not found (Xcode-only projects unsupported)".into()));
    }
    let output = Command::new("swift")
        .args(["test", "--filter", "Bench"])
        .current_dir(root)
        .output();
    let Ok(output) = output else {
        return (1.0, Some("algo_complexity: swift test failed to spawn".into()));
    };
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    // XCTest .measure output: "Test Case '-[FooTests testParse_n100]' passed ... (0.123 seconds)"
    let re = Regex::new(r#"testCase\s+'-\[\w+\s+(\w+_n(\d+))\]'\s+passed.*\(([\d.]+)\s+seconds\)"#).unwrap();
    let mut groups: BTreeMap<String, Vec<(f64, f64)>> = BTreeMap::new();
    for cap in re.captures_iter(&combined) {
        let full_name = cap.get(1).unwrap().as_str();
        let n: f64 = cap.get(2).unwrap().as_str().parse().unwrap_or(0.0);
        let secs: f64 = cap.get(3).unwrap().as_str().parse().unwrap_or(0.0);
        let base = full_name.trim_end_matches(&format!("_n{n}"));
        groups.entry(base.to_string()).or_default().push((n, secs * 1_000_000.0));
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
        Some((group, slope)) => (slope, Some(format!("algo_complexity: worst slope {slope:.3} from group '{group}'"))),
        None => (1.0, Some("algo_complexity: no scaling tests detected (name tests `test*_n10`, `test*_n100`, `test*_n1000`)".into())),
    }
}

fn measure_swift_db_query_cost(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"sqlite3_exec\s*\(",
        r"\.execute\s*\(",
        r"NSFetchRequest\s*<",
        r"NSManagedObjectContext\s*\.\s*fetch\s*\(",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let txn_re = Regex::new(r"(?i)BEGIN\s+TRANSACTION|sqlite3_exec\([^,]*BEGIN").unwrap();
    let mut count: u64 = 0;
    let mut txn: u64 = 0;
    for entry in walkdir::WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| matches!(e.path().extension().and_then(|s| s.to_str()), Some("swift")))
    {
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        for re in &patterns {
            count = count.saturating_add(re.find_iter(&text).count() as u64);
        }
        txn = txn.saturating_add(txn_re.find_iter(&text).count() as u64);
    }
    if count == 0 {
        return (0.0, Some("db_query_cost: no DB queries detected — metric omitted".into()));
    }
    let unbatched = count.saturating_sub(txn);
    (unbatched as f64, Some(format!("db_query_cost: {count} queries, {txn} txns, {unbatched} unbatched")))
}

fn measure_swift_xproc(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"@_silgen_name\s*\(",
        r"@_cdecl\s*\(",
        r"import\s+C\w+",
        r"@objc\s+(class|func)",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let mut count: u64 = 0;
    for entry in walkdir::WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| matches!(e.path().extension().and_then(|s| s.to_str()), Some("swift")))
    {
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        for re in &patterns {
            count = count.saturating_add(re.find_iter(&text).count() as u64);
        }
    }
    if count == 0 {
        return (0.0, Some("xproc_roundtrips: no FFI / @objc bridges detected".into()));
    }
    (count as f64, Some(format!("xproc_roundtrips: {count} bridge declarations / decorators")))
}

fn is_skip_dir(name: &str) -> bool {
    matches!(name, ".build" | "DerivedData" | "node_modules" | ".git" | ".tado" | "Pods")
}

/// Used by other adapters to fill in the registry shape with neutral
/// samples for metrics they don't measure. Kept here because Swift was
/// the first non-Rust adapter to land.
#[allow(dead_code)]
pub(super) fn default_samples(adapter: &str) -> BTreeMap<String, MetricSample> {
    let mut samples = BTreeMap::new();
    samples.insert(algo_complexity::NAME.to_string(), algo_complexity::sample_from_slope(1.0, adapter, None));
    samples.insert(alloc_per_op::NAME.to_string(), alloc_per_op::sample(0.0, adapter, None));
    samples.insert(critical_path_ops::NAME.to_string(), critical_path_ops::sample(0.0, adapter, None));
    samples.insert(io_syscalls_per_op::NAME.to_string(), io_syscalls_per_op::sample(0.0, adapter, None));
    samples.insert(db_query_cost::NAME.to_string(), db_query_cost::sample(0.0, adapter, None));
    samples.insert(xproc_roundtrips::NAME.to_string(), xproc_roundtrips::sample(0.0, adapter, None));
    samples.insert(cold_start_ops::NAME.to_string(), cold_start_ops::sample(0.0, adapter, None));
    samples.insert(steady_state_rss_ratio::NAME.to_string(), steady_state_rss_ratio::sample(1.0, adapter, None));
    samples
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn db_query_cost_counts_swift_queries() {
        let dir = tmpdir("perf-swift-db");
        fs::create_dir_all(dir.path().join("Sources")).unwrap();
        fs::write(
            dir.path().join("Sources/Db.swift"),
            r#"
import SQLite3
func insert() {
    for row in rows {
        sqlite3_exec(db, "INSERT INTO t VALUES (?)", nil, nil, nil)
    }
}
"#,
        ).unwrap();
        let (cost, _note) = measure_swift_db_query_cost(dir.path());
        assert!(cost > 0.0);
    }

    #[test]
    fn xproc_counts_bridges() {
        let dir = tmpdir("perf-swift-bridge");
        fs::create_dir_all(dir.path().join("Sources")).unwrap();
        fs::write(
            dir.path().join("Sources/X.swift"),
            r#"
@_silgen_name("rust_func")
func rustFunc() -> Int32

@objc class Bridge: NSObject {}
"#,
        ).unwrap();
        let (count, _note) = measure_swift_xproc(dir.path());
        assert!(count >= 2.0);
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
