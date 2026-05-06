//! Stack adapters — the pluggable layer that knows how each language /
//! build system surfaces the eight metrics.
//!
//! Each adapter implements `Adapter`. Detection is by fingerprint
//! files in the project root (`Cargo.toml`, `Package.swift`,
//! `package.json`, `pyproject.toml`, `go.mod`). When multiple
//! fingerprints are present, we use the polyglot adapter, which
//! composes the per-language reports and weights by lines-of-code
//! ratio.

use crate::metrics::MetricSample;
use crate::MeasurementContext;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

pub mod go;
pub mod node;
pub mod polyglot;
pub mod python;
pub mod rust;
pub mod swift;

/// Recognized stack tags. Stored on `PerfReport.stack` so the JSON
/// is self-describing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stack {
    Rust,
    Swift,
    Node,
    Python,
    Go,
    Polyglot,
    /// No recognizable stack found. The gate echoes
    /// `PERF: NO-STACK-DETECTED` and exits cleanly.
    Unknown,
}

impl fmt::Display for Stack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Stack::Rust => f.write_str("rust"),
            Stack::Swift => f.write_str("swift"),
            Stack::Node => f.write_str("node"),
            Stack::Python => f.write_str("python"),
            Stack::Go => f.write_str("go"),
            Stack::Polyglot => f.write_str("polyglot"),
            Stack::Unknown => f.write_str("unknown"),
        }
    }
}

#[derive(Debug)]
pub enum AdapterError {
    Detection(String),
    Correctness { stack: Stack, exit_code: i32, stderr: String },
    Measurement(String),
    Io(std::io::Error),
}

impl fmt::Display for AdapterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AdapterError::Detection(s) => write!(f, "stack detection failed: {s}"),
            AdapterError::Correctness { stack, exit_code, stderr } => write!(
                f,
                "correctness gate failed for {stack} (exit {exit_code}): {stderr}",
            ),
            AdapterError::Measurement(s) => write!(f, "measurement failed: {s}"),
            AdapterError::Io(e) => write!(f, "io error: {e}"),
        }
    }
}

impl std::error::Error for AdapterError {}

impl From<std::io::Error> for AdapterError {
    fn from(value: std::io::Error) -> Self {
        AdapterError::Io(value)
    }
}

/// What every stack adapter exposes.
pub trait Adapter {
    fn stack(&self) -> Stack;
    /// Run the project's correctness tests. Must return `Ok(())` on
    /// pass; any other path means the gate refuses to score and
    /// emits `PERF: CORRECTNESS-FAILED`.
    fn correctness_gate(&self, ctx: &MeasurementContext) -> Result<(), AdapterError>;
    /// Produce a sample for each metric the adapter supports. Adapters
    /// are encouraged to return Ok with partial samples (only the
    /// metrics they can actually measure) — scoring proportionally
    /// redistributes the weight of omitted metrics.
    fn measure(
        &self,
        ctx: &MeasurementContext,
    ) -> Result<(BTreeMap<String, MetricSample>, BTreeMap<String, String>), AdapterError>;
}

/// Detect the stack from project root files. Multi-stack projects
/// return Polyglot.
pub fn detect_stack(project_root: &Path) -> Stack {
    let has_rust = project_root.join("Cargo.toml").exists();
    let has_swift = project_root.join("Package.swift").exists()
        || has_xcode_project(project_root);
    let has_node = project_root.join("package.json").exists();
    let has_python = project_root.join("pyproject.toml").exists()
        || project_root.join("setup.py").exists();
    let has_go = project_root.join("go.mod").exists();

    let count = [has_rust, has_swift, has_node, has_python, has_go]
        .iter()
        .filter(|x| **x)
        .count();
    if count >= 2 {
        return Stack::Polyglot;
    }
    if has_rust {
        return Stack::Rust;
    }
    if has_swift {
        return Stack::Swift;
    }
    if has_node {
        return Stack::Node;
    }
    if has_python {
        return Stack::Python;
    }
    if has_go {
        return Stack::Go;
    }
    Stack::Unknown
}

fn has_xcode_project(root: &Path) -> bool {
    if let Ok(entries) = std::fs::read_dir(root) {
        for e in entries.flatten() {
            if let Some(name) = e.file_name().to_str() {
                if name.ends_with(".xcodeproj") || name.ends_with(".xcworkspace") {
                    return true;
                }
            }
        }
    }
    false
}

/// Pick the adapter for a stack. Returns `None` for `Stack::Unknown`
/// since there's nothing to measure.
pub fn detect_adapter(project_root: &Path) -> Option<Box<dyn Adapter>> {
    match detect_stack(project_root) {
        Stack::Rust => Some(Box::new(rust::RustAdapter)),
        Stack::Swift => Some(Box::new(swift::SwiftAdapter)),
        Stack::Node => Some(Box::new(node::NodeAdapter)),
        Stack::Python => Some(Box::new(python::PythonAdapter)),
        Stack::Go => Some(Box::new(go::GoAdapter)),
        Stack::Polyglot => Some(Box::new(polyglot::PolyglotAdapter)),
        Stack::Unknown => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn detect_rust_from_cargo_toml() {
        let dir = tempdir();
        fs::write(dir.path().join("Cargo.toml"), "[package]\nname='x'\n").unwrap();
        assert_eq!(detect_stack(dir.path()), Stack::Rust);
    }

    #[test]
    fn detect_node_from_package_json() {
        let dir = tempdir();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert_eq!(detect_stack(dir.path()), Stack::Node);
    }

    #[test]
    fn detect_polyglot_when_two_present() {
        let dir = tempdir();
        fs::write(dir.path().join("Cargo.toml"), "").unwrap();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert_eq!(detect_stack(dir.path()), Stack::Polyglot);
    }

    #[test]
    fn detect_unknown_when_empty() {
        let dir = tempdir();
        assert_eq!(detect_stack(dir.path()), Stack::Unknown);
    }

    /// Tiny private temp-dir helper so we don't pull a tempfile dep.
    /// Cleaned up on drop via the wrapper struct.
    fn tempdir() -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "perf-suite-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&path).unwrap();
        TempDir { path }
    }

    struct TempDir {
        path: std::path::PathBuf,
    }
    impl TempDir {
        fn path(&self) -> &std::path::Path {
            &self.path
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}
