//! Polyglot stack adapter — production implementation.
//!
//! Active when more than one stack fingerprint is present in the
//! project root. Composes per-language reports weighted by
//! lines-of-code ratio so a 90% Rust + 10% Node project doesn't get
//! its perf score swamped by Node's slower benches.
//!
//! Correctness gate: runs each detected stack's correctness gate;
//! ALL must pass.
//!
//! Measurement strategy:
//!   1. Detect every stack present at the root (rust, swift, node,
//!      python, go).
//!   2. Compute per-stack LOC ratio by walking files with each stack's
//!      extension set.
//!   3. Run each stack's adapter.measure() in turn.
//!   4. For each metric: weight the per-stack samples by LOC ratio,
//!      sum to a single value. Notes are concatenated with a per-stack
//!      prefix.

use super::{Adapter, AdapterError, Stack};
use crate::metrics::{registry, MetricSample};
use crate::MeasurementContext;
use std::collections::BTreeMap;
use std::path::Path;

pub struct PolyglotAdapter;

impl Adapter for PolyglotAdapter {
    fn stack(&self) -> Stack {
        Stack::Polyglot
    }

    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError> {
        for (present, adapter) in active_adapters(&ctx.project_root) {
            if !present {
                continue;
            }
            adapter.correctness_gate(ctx)?;
        }
        Ok(())
    }

    fn measure(
        &self,
        ctx: &MeasurementContext,
    ) -> Result<(BTreeMap<String, MetricSample>, BTreeMap<String, String>), AdapterError> {
        let adapters = active_adapters(&ctx.project_root);
        let active: Vec<Box<dyn Adapter>> = adapters
            .into_iter()
            .filter_map(|(p, a)| if p { Some(a) } else { None })
            .collect();
        if active.is_empty() {
            return Ok((BTreeMap::new(), BTreeMap::new()));
        }
        let weights = stack_loc_weights(&ctx.project_root, &active);

        let mut combined: BTreeMap<String, Vec<(f64, MetricSample)>> = BTreeMap::new();
        let mut combined_notes: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (i, adapter) in active.iter().enumerate() {
            let weight = weights.get(i).copied().unwrap_or(0.0);
            if weight <= 0.0 { continue; }
            let (samples, notes) = adapter.measure(ctx)?;
            for (name, sample) in samples {
                combined.entry(name.clone()).or_default().push((weight, sample));
            }
            for (name, note) in notes {
                combined_notes.entry(name).or_default().push(format!("[{}] {}", adapter.stack(), note));
            }
        }

        let mut samples = BTreeMap::new();
        let mut notes = BTreeMap::new();
        for (metric_name, _, _direction) in registry() {
            let Some(weighted) = combined.get(metric_name) else { continue };
            // Weighted mean of present (non-zero) samples.
            let mut total: f64 = 0.0;
            let mut wsum: f64 = 0.0;
            let mut adapter_label = String::new();
            let mut direction = crate::metrics::Direction::LowerIsBetter;
            let mut unit = String::new();
            for (w, s) in weighted {
                if s.value <= 0.0 && metric_name != "steady_state_rss_ratio" { continue; }
                total += w * s.value;
                wsum += w;
                adapter_label = "polyglot".into();
                direction = s.direction;
                unit = s.unit.clone();
            }
            let value = if wsum > 0.0 { total / wsum } else { 0.0 };
            samples.insert(
                metric_name.to_string(),
                MetricSample {
                    value,
                    unit: if unit.is_empty() { "weighted".into() } else { unit },
                    direction,
                    adapter: if adapter_label.is_empty() { "polyglot".into() } else { adapter_label },
                    notes: combined_notes.get(metric_name).map(|v| v.join("; ")),
                },
            );
        }
        for (name, lines) in combined_notes {
            notes.insert(name, lines.join(" | "));
        }
        Ok((samples, notes))
    }
}

/// Returns one (present, adapter) tuple per supported stack so the
/// caller can iterate without re-detecting.
fn active_adapters(root: &Path) -> Vec<(bool, Box<dyn Adapter>)> {
    vec![
        (root.join("Cargo.toml").exists(), Box::new(super::rust::RustAdapter) as Box<dyn Adapter>),
        (root.join("Package.swift").exists(), Box::new(super::swift::SwiftAdapter)),
        (root.join("package.json").exists(), Box::new(super::node::NodeAdapter)),
        (
            root.join("pyproject.toml").exists() || root.join("setup.py").exists(),
            Box::new(super::python::PythonAdapter),
        ),
        (root.join("go.mod").exists(), Box::new(super::go::GoAdapter)),
    ]
}

/// LOC-based weighting. Counts source files per language under the
/// project root. Returns one weight per active adapter, normalized to
/// sum to 1.0. Equal weighting fallback when LOC count fails.
fn stack_loc_weights(root: &Path, adapters: &[Box<dyn Adapter>]) -> Vec<f64> {
    let mut totals: Vec<u64> = vec![0; adapters.len()];
    for (idx, adapter) in adapters.iter().enumerate() {
        let exts: &[&str] = match adapter.stack() {
            Stack::Rust => &["rs"],
            Stack::Swift => &["swift"],
            Stack::Node => &["js", "ts", "mjs", "cjs", "tsx", "jsx"],
            Stack::Python => &["py"],
            Stack::Go => &["go"],
            _ => &[],
        };
        if exts.is_empty() {
            continue;
        }
        for entry in walkdir::WalkDir::new(root)
            .into_iter()
            .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
        {
            let Some(ext) = entry.path().extension().and_then(|s| s.to_str()) else { continue };
            if !exts.contains(&ext) { continue; }
            let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
            totals[idx] = totals[idx].saturating_add(text.lines().count() as u64);
        }
    }
    let total: u64 = totals.iter().sum();
    if total == 0 {
        // Equal weighting fallback.
        let n = adapters.len() as f64;
        return vec![1.0 / n; adapters.len()];
    }
    totals.iter().map(|&t| t as f64 / total as f64).collect()
}

fn is_skip_dir(name: &str) -> bool {
    matches!(
        name,
        "target" | "node_modules" | ".git" | ".tado" | "dist" | "build" | ".next"
        | ".build" | "DerivedData" | "Pods" | "venv" | ".venv" | "__pycache__"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn loc_weights_sum_to_one() {
        let dir = tmpdir("perf-poly-loc");
        fs::write(dir.path().join("Cargo.toml"), "[package]\nname='x'\n").unwrap();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        // 3 lines of Rust, 7 lines of TS — Rust weight ~0.3
        fs::write(dir.path().join("src/lib.rs"), "fn a() {}\nfn b() {}\nfn c() {}").unwrap();
        fs::write(dir.path().join("a.ts"), "1\n2\n3\n4\n5\n6\n7\n").unwrap();
        let adapters = active_adapters(dir.path());
        let active: Vec<Box<dyn Adapter>> = adapters.into_iter().filter_map(|(p, a)| if p { Some(a) } else { None }).collect();
        let weights = stack_loc_weights(dir.path(), &active);
        let sum: f64 = weights.iter().sum();
        assert!((sum - 1.0).abs() < 1e-6);
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
