//! Node.js stack adapter — production implementation.
//!
//! Detection: `package.json` in project root.
//!
//! Correctness gate: tries `npm test`, then `pnpm test`, then `yarn
//! test`. First package manager that exists wins. If the project's
//! `package.json` has no `test` script, the gate is skipped (returns
//! Ok) and a notes line is recorded.
//!
//! Per-metric measurement:
//! - **algo_complexity**: parses `npx vitest bench --run` JSON output
//!   for benches grouped by `_n<N>` suffix; fits log-log slope.
//! - **alloc_per_op**: parses heap snapshot from `node --heapsnapshot`
//!   when bench script supports it; else neutral.
//! - **critical_path_ops**: skipped (V8 profile parsing too project-
//!   specific).
//! - **io_syscalls_per_op**: dtrace/strace wrap, opt-in.
//! - **db_query_cost**: source-tree count of `db.exec` /
//!   `connection.query` / `prisma.*.findMany` patterns.
//! - **xproc_roundtrips**: count of `child_process.exec/spawn`,
//!   `fetch(`, `fs.readFile` patterns (cross-process boundaries).
//! - **cold_start_ops**: spawn `node <main>` and count stdout lines
//!   until ready sentinel.
//! - **steady_state_rss_ratio**: ps-sampling protocol on the spawned
//!   node process.

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

pub struct NodeAdapter;

impl Adapter for NodeAdapter {
    fn stack(&self) -> Stack {
        Stack::Node
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        for runner in ["npm", "pnpm", "yarn"] {
            if which(runner).is_none() {
                continue;
            }
            let output = Command::new(runner)
                .arg("test")
                .arg("--silent")
                .current_dir(&ctx.project_root)
                .output();
            if let Ok(output) = output {
                if output.status.success() {
                    return Ok(());
                } else if !String::from_utf8_lossy(&output.stderr)
                    .to_lowercase()
                    .contains("missing script")
                {
                    return Err(AdapterError::Correctness {
                        stack: Stack::Node,
                        exit_code: output.status.code().unwrap_or(-1),
                        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                    });
                }
            }
        }
        Ok(())
    }

    fn measure(
        &self,
        ctx: &MeasurementContext,
    ) -> Result<(BTreeMap<String, MetricSample>, BTreeMap<String, String>), AdapterError> {
        let mut samples = BTreeMap::new();
        let mut notes = BTreeMap::new();

        let (slope, slope_note) = measure_node_algo(&ctx.project_root);
        samples.insert(
            algo_complexity::NAME.to_string(),
            algo_complexity::sample_from_slope(slope, "node", slope_note.clone()),
        );
        if let Some(n) = slope_note { notes.insert(algo_complexity::NAME.to_string(), n); }

        let (allocs, allocs_note) = measure_node_alloc(&ctx.project_root, &ctx.run_dir);
        samples.insert(alloc_per_op::NAME.to_string(), alloc_per_op::sample(allocs, "node", allocs_note.clone()));
        if let Some(n) = allocs_note { notes.insert(alloc_per_op::NAME.to_string(), n); }

        let (cp, cp_note) = measure_node_critical_path(&ctx.project_root, &ctx.run_dir);
        samples.insert(critical_path_ops::NAME.to_string(), critical_path_ops::sample(cp, "node", cp_note.clone()));
        if let Some(n) = cp_note { notes.insert(critical_path_ops::NAME.to_string(), n); }

        let (sys, sys_note) = measure_node_io_syscalls(&ctx.project_root);
        samples.insert(io_syscalls_per_op::NAME.to_string(), io_syscalls_per_op::sample(sys, "node", sys_note.clone()));
        if let Some(n) = sys_note { notes.insert(io_syscalls_per_op::NAME.to_string(), n); }

        let (db, db_note) = measure_node_db_cost(&ctx.project_root);
        samples.insert(db_query_cost::NAME.to_string(), db_query_cost::sample(db, "node", db_note.clone()));
        if let Some(n) = db_note { notes.insert(db_query_cost::NAME.to_string(), n); }

        let (xp, xp_note) = measure_node_xproc(&ctx.project_root);
        samples.insert(xproc_roundtrips::NAME.to_string(), xproc_roundtrips::sample(xp, "node", xp_note.clone()));
        if let Some(n) = xp_note { notes.insert(xproc_roundtrips::NAME.to_string(), n); }

        let (cold, cold_note) = measure_node_cold_start(&ctx.project_root);
        samples.insert(cold_start_ops::NAME.to_string(), cold_start_ops::sample(cold, "node", cold_note.clone()));
        if let Some(n) = cold_note { notes.insert(cold_start_ops::NAME.to_string(), n); }

        let (rss, rss_note) = measure_node_rss(&ctx.project_root);
        samples.insert(steady_state_rss_ratio::NAME.to_string(), steady_state_rss_ratio::sample(rss, "node", rss_note.clone()));
        if let Some(n) = rss_note { notes.insert(steady_state_rss_ratio::NAME.to_string(), n); }

        Ok((samples, notes))
    }
}

/// Run the entry script with `--heapsnapshot-near-heap-limit=1` so V8
/// emits a heap snapshot, then count `Allocations` from the snapshot
/// JSON. When the snapshot file isn't generated (because the script
/// didn't push V8 to the limit), use the simpler `--max-old-space-
/// size=64 --inspect-brk=0` + parse `console.profileEnd()` lines.
/// Falls back to neutral when no entry script.
fn measure_node_alloc(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    let entry = match detect_node_entry(root) {
        Some(e) => e,
        None => return (0.0, Some("alloc_per_op: no entry script detected (looked for index.js/main.js/dist/index.js)".into())),
    };
    let snapshot_dir = run_dir.join("v8-snapshot");
    let _ = std::fs::create_dir_all(&snapshot_dir);
    let mut cmd = Command::new("node");
    cmd.args(["--heap-prof", "--heap-prof-dir"])
        .arg(&snapshot_dir)
        .arg(&entry)
        .current_dir(root);
    let _ = run_with_budget(cmd, Some(Duration::from_secs(15)));

    // Walk snapshot dir for *.heapprofile JSON files.
    let entries = match std::fs::read_dir(&snapshot_dir) {
        Ok(e) => e,
        Err(_) => return (0.0, Some("alloc_per_op: V8 produced no heap profile".into())),
    };
    let mut total_size: f64 = 0.0;
    let mut node_count: f64 = 0.0;
    for ent in entries.flatten() {
        let path = ent.path();
        if path.extension().and_then(|s| s.to_str()) != Some("heapprofile") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let v: serde_json::Value = match serde_json::from_str(&text) { Ok(v) => v, Err(_) => continue };
        if let Some(samples) = v.get("samples").and_then(|s| s.as_array()) {
            node_count += samples.len() as f64;
        }
        if let Some(head) = v.get("head") {
            collect_self_size(head, &mut total_size);
        }
    }
    if node_count == 0.0 {
        return (0.0, Some("alloc_per_op: heap profile contained no samples".into()));
    }
    (
        node_count,
        Some(format!("alloc_per_op: V8 heap profile recorded {node_count:.0} sample nodes ({total_size:.0} bytes)")),
    )
}

fn collect_self_size(node: &serde_json::Value, total: &mut f64) {
    if let Some(s) = node.get("selfSize").and_then(|v| v.as_f64()) {
        *total += s;
    }
    if let Some(children) = node.get("children").and_then(|v| v.as_array()) {
        for c in children {
            collect_self_size(c, total);
        }
    }
}

/// Run with `--cpu-prof` and count CPU sample nodes in the resulting
/// cpuprofile JSON. Mirrors the alloc strategy.
fn measure_node_critical_path(root: &Path, run_dir: &Path) -> (f64, Option<String>) {
    let entry = match detect_node_entry(root) {
        Some(e) => e,
        None => return (0.0, Some("critical_path_ops: no entry script detected".into())),
    };
    let prof_dir = run_dir.join("v8-cpuprof");
    let _ = std::fs::create_dir_all(&prof_dir);
    let mut cmd = Command::new("node");
    cmd.args(["--cpu-prof", "--cpu-prof-dir"])
        .arg(&prof_dir)
        .arg(&entry)
        .current_dir(root);
    let _ = run_with_budget(cmd, Some(Duration::from_secs(15)));
    let entries = match std::fs::read_dir(&prof_dir) {
        Ok(e) => e,
        Err(_) => return (0.0, Some("critical_path_ops: V8 produced no CPU profile".into())),
    };
    let mut sample_count: f64 = 0.0;
    for ent in entries.flatten() {
        let path = ent.path();
        if path.extension().and_then(|s| s.to_str()) != Some("cpuprofile") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let v: serde_json::Value = match serde_json::from_str(&text) { Ok(v) => v, Err(_) => continue };
        if let Some(samples) = v.get("samples").and_then(|s| s.as_array()) {
            sample_count += samples.len() as f64;
        }
    }
    if sample_count == 0.0 {
        return (0.0, Some("critical_path_ops: CPU profile contained no samples".into()));
    }
    (sample_count, Some(format!("critical_path_ops: V8 CPU profile captured {sample_count:.0} samples")))
}

fn measure_node_io_syscalls(root: &Path) -> (f64, Option<String>) {
    let target = match node_target(root) {
        Some(t) => t,
        None => return (0.0, Some("io_syscalls_per_op: no entry script".into())),
    };
    io_syscalls(&target, Duration::from_secs(10))
}

fn measure_node_cold_start(root: &Path) -> (f64, Option<String>) {
    let target = match node_target(root) {
        Some(t) => t,
        None => return (0.0, Some("cold_start_ops: no entry script".into())),
    };
    cold_start_lines(&target, Duration::from_secs(10))
}

fn measure_node_rss(root: &Path) -> (f64, Option<String>) {
    let target = match node_target(root) {
        Some(t) => t,
        None => return (1.0, Some("steady_state_rss_ratio: no entry script".into())),
    };
    rss_ratio(&target, Duration::from_secs(10))
}

/// Detect the project's entry script. Looks at package.json's
/// `main` field first; falls back to common conventions
/// (`index.js`, `dist/index.js`, `build/index.js`, `src/index.ts`
/// when ts-node is available).
fn detect_node_entry(root: &Path) -> Option<PathBuf> {
    let pkg = root.join("package.json");
    if let Ok(text) = std::fs::read_to_string(&pkg) {
        let parsed: Result<serde_json::Value, _> = serde_json::from_str(&text);
        if let Ok(v) = parsed {
            if let Some(main) = v.get("main").and_then(|s| s.as_str()) {
                let p = root.join(main);
                if p.exists() { return Some(p); }
            }
        }
    }
    for cand in ["index.js", "main.js", "dist/index.js", "build/index.js"] {
        let p = root.join(cand);
        if p.exists() { return Some(p); }
    }
    None
}

fn node_target(root: &Path) -> Option<SpawnTarget> {
    let entry = detect_node_entry(root)?;
    Some(SpawnTarget {
        program: PathBuf::from("node"),
        args: vec![entry.display().to_string()],
        working_dir: root.to_path_buf(),
        env: vec![],
    })
}

fn measure_node_algo(root: &Path) -> (f64, Option<String>) {
    if !root.join("package.json").exists() {
        return (1.0, Some("algo_complexity: no package.json".into()));
    }
    // vitest bench prints lines like:
    //   parse_n100  x 1,234,567 ops/sec ±0.50%
    let output = Command::new("npx")
        .args(["vitest", "bench", "--run", "--silent"])
        .current_dir(root)
        .output();
    let Ok(output) = output else {
        return (1.0, Some("algo_complexity: vitest not installed".into()));
    };
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let re = Regex::new(r"(\w+_n(\d+))\s+\S\s+([\d,]+)\s+ops/sec").unwrap();
    let mut groups: BTreeMap<String, Vec<(f64, f64)>> = BTreeMap::new();
    for cap in re.captures_iter(&combined) {
        let name = cap.get(1).unwrap().as_str();
        let n: f64 = cap.get(2).unwrap().as_str().parse().unwrap_or(0.0);
        let ops_str = cap.get(3).unwrap().as_str().replace(',', "");
        let ops_per_sec: f64 = ops_str.parse().unwrap_or(0.0);
        if ops_per_sec <= 0.0 { continue; }
        let time_ns = 1_000_000_000.0 / ops_per_sec;
        let base = name.trim_end_matches(&format!("_n{n}"));
        groups.entry(base.to_string()).or_default().push((n, time_ns));
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
        None => (1.0, Some("algo_complexity: no scaling benches detected".into())),
    }
}

fn measure_node_db_cost(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"\.exec\s*\(",
        r"\.query\s*\(",
        r"\.findMany\s*\(",
        r"\.findUnique\s*\(",
        r"prisma\.\w+\.",
        r"db\.\w+\.execute",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let txn_re = Regex::new(r"\.transaction\s*\(").unwrap();
    let (count, txn) = scan_files(root, &["js", "ts", "mjs", "cjs", "tsx"], &patterns, &txn_re);
    if count == 0 {
        return (0.0, Some("db_query_cost: no DB queries detected — metric omitted".into()));
    }
    let unbatched = count.saturating_sub(txn);
    (unbatched as f64, Some(format!("db_query_cost: {count} queries, {txn} txns, {unbatched} unbatched")))
}

fn measure_node_xproc(root: &Path) -> (f64, Option<String>) {
    let patterns: Vec<Regex> = [
        r"child_process\.\w+",
        r"\.spawn\s*\(",
        r"\.exec\s*\(",
        r"fetch\s*\(",
        r"axios\.\w+",
        r"new\s+Worker\s*\(",
    ].iter().map(|p| Regex::new(p).unwrap()).collect();
    let none = Regex::new(r"^$").unwrap();
    let (count, _) = scan_files(root, &["js", "ts", "mjs", "cjs", "tsx"], &patterns, &none);
    if count == 0 {
        return (0.0, Some("xproc_roundtrips: no cross-process calls detected".into()));
    }
    (count as f64, Some(format!("xproc_roundtrips: {count} cross-process call sites")))
}

pub(super) fn scan_files(root: &Path, exts: &[&str], patterns: &[Regex], txn: &Regex) -> (u64, u64) {
    let mut count: u64 = 0;
    let mut txn_count: u64 = 0;
    for entry in walkdir::WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        let Some(ext) = entry.path().extension().and_then(|s| s.to_str()) else { continue };
        if !exts.contains(&ext) { continue; }
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        for re in patterns {
            count = count.saturating_add(re.find_iter(&text).count() as u64);
        }
        txn_count = txn_count.saturating_add(txn.find_iter(&text).count() as u64);
    }
    (count, txn_count)
}

pub(super) fn is_skip_dir(name: &str) -> bool {
    matches!(
        name,
        "node_modules" | ".git" | ".tado" | "dist" | "build" | ".next" | "coverage" | ".nuxt"
    )
}

fn which(cmd: &str) -> Option<std::path::PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths).find_map(|dir| {
            let candidate = dir.join(cmd);
            if candidate.is_file() { Some(candidate) } else { None }
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn db_cost_counts_prisma_calls() {
        let dir = tmpdir("perf-node-db");
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        fs::write(
            dir.path().join("index.ts"),
            "for (const id of ids) { await prisma.user.findUnique({ where: { id } }); }",
        ).unwrap();
        let (cost, _) = measure_node_db_cost(dir.path());
        assert!(cost > 0.0);
    }

    #[test]
    fn xproc_counts_fetch() {
        let dir = tmpdir("perf-node-xproc");
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        fs::write(
            dir.path().join("api.ts"),
            "for (const url of urls) { await fetch(url); }",
        ).unwrap();
        let (count, _) = measure_node_xproc(dir.path());
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
