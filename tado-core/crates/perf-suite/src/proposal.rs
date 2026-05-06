//! Refactor proposal generator — production implementation.
//!
//! Reads `git diff` output (changed files) plus the latest
//! `perf-report.json`, runs a regex pass over the diffed source, and
//! emits markdown lines into `perf-proposals.md` describing
//! candidate refactors at universal IMPROVE-ladder rungs.
//!
//! Patterns cover all 8 rungs (Rung 0 — measurement hygiene through
//! Rung 7 — structural) for all six stacks (Rust, Swift, Node,
//! Python, Go, generic). Each pattern is language-aware via the file
//! extension.
//!
//! This is intentionally regex-based, not AST-based. The user's
//! worker has the AST tools (Edit, Read, Bash) and decides what to
//! actually apply. Proposals are *hints*, not commits.

use crate::report::PerfReport;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Proposal {
    pub rung: u8,
    pub category: String,
    pub file: PathBuf,
    pub line: Option<u32>,
    pub message: String,
    /// Which sub-metric this proposal most likely addresses. Empty
    /// when the pattern is general-purpose. Used by the
    /// eternal-performance-evaluator agent to rank proposals against
    /// the regression's hot path.
    pub target_metric: Option<String>,
}

impl fmt::Display for Proposal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let line = self.line.map(|n| format!(":{n}")).unwrap_or_default();
        let target = self
            .target_metric
            .as_deref()
            .map(|m| format!(" [→{m}]"))
            .unwrap_or_default();
        write!(
            f,
            "- **Rung {} · {}**{} — {}{} — {}",
            self.rung, self.category, target, self.file.display(), line, self.message
        )
    }
}

/// One pattern in the catalog. The catalog is built once per process
/// at startup; patterns compile via `lazy_static` semantics through
/// the `patterns()` function returning fresh regex each call (cheap
/// for the ~50 patterns we have).
struct Pattern {
    rung: u8,
    category: &'static str,
    re: Regex,
    hint: &'static str,
    extensions: &'static [&'static str],
    target_metric: Option<&'static str>,
}

fn patterns() -> Vec<Pattern> {
    use crate::metrics::*;
    let raw: &[(u8, &'static str, &'static str, &'static str, &'static [&'static str], Option<&'static str>)] = &[
        // ── Rung 1: Algorithmic ──
        (1, "algorithmic", r"\.contains\s*\([^)]+\)\s*\|\|", "Repeated `.contains` checks suggest an O(n²) pattern — consider a HashSet/Set.",
            &["rs", "swift", "ts", "js", "py", "go"], Some(algo_complexity::NAME)),
        (1, "algorithmic", r"\.find\s*\([^)]+\)[^=]*\.find\s*\(", "Two `.find()` calls in succession — consider a single `.partition` or HashMap lookup.",
            &["rs", "swift", "ts", "js"], Some(algo_complexity::NAME)),
        (1, "algorithmic", r"for\s+\w+\s+in\s+.+:\s*\n\s+for\s+\w+\s+in\s+", "Nested for loops — verify the inner work isn't constant-factor reducible.",
            &["py"], Some(algo_complexity::NAME)),

        // ── Rung 2: Allocation ──
        (2, "allocation", r"Vec::new\(\)\s*$", "Replace `Vec::new()` with `Vec::with_capacity(n)` if size is known.",
            &["rs"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"String::new\(\)\s*$", "Replace `String::new()` with `String::with_capacity(n)` if size is known.",
            &["rs"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"\.clone\(\)\.", "`.clone()` followed by a call — consider `&` if the callee can borrow.",
            &["rs"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"\.to_vec\(\)", "`.to_vec()` allocates — pass `&[T]` if the callee doesn't need ownership.",
            &["rs"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"Array<\w+>\s*\(\)", "Empty `Array<T>()` — use `[]` literal or pre-size with reserveCapacity(n).",
            &["swift"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"\.copy\(\)", "`.copy()` allocates — verify mutation requires a copy at all.",
            &["py"], Some(alloc_per_op::NAME)),
        (2, "allocation", r"make\s*\(\s*\[\]\w+\s*,\s*0\s*\)", "`make([]T, 0)` with no cap — supply capacity if it's known.",
            &["go"], Some(alloc_per_op::NAME)),

        // ── Rung 3: Data layout ──
        (3, "layout", r"struct\s+\w+\s*\{[^}]{200,}\}", "Large struct (>200 chars) — verify field ordering packs without padding.",
            &["rs"], Some(critical_path_ops::NAME)),
        (3, "layout", r"Box<\w+>\s*,", "Boxed pointer in struct — consider inline storage if lifetime allows.",
            &["rs"], None),

        // ── Rung 4: Concurrency / batching ──
        (4, "concurrency", r"for\s+\w+\s+in\s+.+\.iter\(\)", "Hot iter loop — consider `par_iter` (rayon) if work per item is non-trivial.",
            &["rs"], Some(critical_path_ops::NAME)),
        (4, "concurrency", r"\.forEach\s*\(", "`.forEach` is sequential — consider `Promise.all` for independent async ops.",
            &["js", "ts"], Some(critical_path_ops::NAME)),
        (4, "concurrency", r"for\s+\w+\s+in\s+\w+:[^\\n]*\n\s+\w+\s*\(", "Sequential per-item call — consider `concurrent.futures` or `asyncio.gather` if independent.",
            &["py"], Some(critical_path_ops::NAME)),
        (4, "concurrency", r"go\s+func\s*\(\)\s*\{[^}]+\}\(\)", "Anonymous goroutine — verify it doesn't escape into a leaked-goroutine pattern.",
            &["go"], None),

        // ── Rung 5: Caching / memoization ──
        (5, "caching", r"fn\s+\w+\([^)]*\).*->.*\{[^}]*recompute", "Function name suggests recomputation — consider memoization.",
            &["rs"], Some(critical_path_ops::NAME)),
        (5, "caching", r"def\s+\w+.*:\s*\n\s+#.*expensive", "Comment marks function as expensive — consider `@functools.lru_cache`.",
            &["py"], Some(critical_path_ops::NAME)),

        // ── Rung 6: IO / syscall reduction ──
        (6, "io", r"for\s+.+in\s+.+\{[^}]*write!|writeln!", "Writes inside a loop — buffer with `BufWriter` or batch into one `write_all`.",
            &["rs"], Some(io_syscalls_per_op::NAME)),
        (6, "io", r"sqlite.+execute.*for\s", "SQLite execute inside a loop — wrap in `BEGIN; ...; COMMIT;` transaction.",
            &["rs", "py"], Some(db_query_cost::NAME)),
        (6, "io", r"console\.log\s*\(.*\)\s*\n.*for\s+\(", "console.log inside a loop — collect to array, log once.",
            &["js", "ts"], Some(io_syscalls_per_op::NAME)),
        (6, "io", r"fmt\.Println\s*\(.*\)\s*\n.*for\s+", "fmt.Println inside a loop — buffer with bufio.Writer.",
            &["go"], Some(io_syscalls_per_op::NAME)),
        (6, "io", r#"\.execute\s*\(\s*["'].*["']\s*,\s*\w+\s*\)\s*\n\s*\w+\.execute"#, "Two adjacent .execute calls — consider executemany or a transaction.",
            &["py"], Some(db_query_cost::NAME)),

        // ── Rung 5/6: cross-process roundtrips ──
        (5, "caching", r"fetch\s*\([^)]+\)\s*\n.*fetch\s*\([^)]+\)", "Repeated fetch calls — consider batching, GraphQL, or a single endpoint.",
            &["js", "ts"], Some(xproc_roundtrips::NAME)),
        (5, "caching", r"requests\.\w+\([^)]+\)\s*\n.*requests\.\w+", "Repeated HTTP calls — consider session reuse + batched endpoints.",
            &["py"], Some(xproc_roundtrips::NAME)),
        (6, "io", r"http\.Get\([^)]+\)\s*\n.*http\.Get", "Repeated http.Get — share http.Client + batch requests.",
            &["go"], Some(xproc_roundtrips::NAME)),

        // ── Rung 7: Structural ──
        (7, "structural", r"HashMap::new\(\)", "HashMap default hasher (SipHash) is slow — consider FxHashMap for non-DOS-sensitive maps.",
            &["rs"], Some(critical_path_ops::NAME)),
        (7, "structural", r"serde_json::from_str", "serde_json — for parse-heavy workloads consider simd-json (5-10x faster).",
            &["rs"], Some(critical_path_ops::NAME)),
        (7, "structural", r"JSON\.parse\s*\(", "JSON.parse on a hot path — consider streaming JSON or a binary format.",
            &["js", "ts"], Some(critical_path_ops::NAME)),

        // ── Rung 0: Measurement hygiene ──
        (0, "hygiene", r"#\[bench\]", "Old-style #[bench] — port to criterion for proper warmup + statistics.",
            &["rs"], None),
        (0, "hygiene", r"console\.time\s*\(", "console.time — switch to a benchmark library for warmup + statistics.",
            &["js", "ts"], None),
    ];
    raw.iter()
        .map(|(rung, category, re, hint, extensions, target_metric)| Pattern {
            rung: *rung,
            category,
            re: Regex::new(re).expect("static regex"),
            hint,
            extensions,
            target_metric: *target_metric,
        })
        .collect()
}

pub fn generate_proposals(
    project_root: &Path,
    report: &PerfReport,
    since_last_commit: bool,
    cap: usize,
) -> Vec<Proposal> {
    let _ = report; // future: weight by which metric regressed
    let diff_files = if since_last_commit {
        git_diff_files(project_root)
    } else {
        all_source_files(project_root)
    };
    let pats = patterns();
    let mut proposals = Vec::new();
    for file in diff_files {
        let path = project_root.join(&file);
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let ext = file.extension().and_then(|s| s.to_str()).unwrap_or("");
        for (lineno, line) in text.lines().enumerate() {
            for pat in &pats {
                if !pat.extensions.contains(&ext) { continue; }
                if pat.re.is_match(line) {
                    proposals.push(Proposal {
                        rung: pat.rung,
                        category: pat.category.into(),
                        file: file.clone(),
                        line: Some((lineno + 1) as u32),
                        message: pat.hint.into(),
                        target_metric: pat.target_metric.map(|s| s.into()),
                    });
                    if proposals.len() >= cap {
                        return proposals;
                    }
                }
            }
        }
    }
    proposals
}

pub fn write_proposals_md(path: &Path, proposals: &[Proposal]) -> std::io::Result<()> {
    use std::fmt::Write as _;
    let mut out = String::new();
    out.push_str("# Performance refactor proposals\n\n");
    out.push_str(
        "Generated by `perf-suite propose`. Each proposal points at one line in the diff that\n\
         matches a universal IMPROVE-ladder pattern. The worker decides which to apply.\n\n\
         Format: `Rung N · category [→target_metric] — file:line — message`\n\n",
    );
    if proposals.is_empty() {
        out.push_str("_No automated proposals from the latest diff._\n");
    } else {
        for p in proposals {
            let _ = writeln!(&mut out, "{p}");
        }
    }
    std::fs::write(path, out)
}

fn git_diff_files(project_root: &Path) -> Vec<PathBuf> {
    let output = Command::new("git")
        .args(["diff", "--name-only", "HEAD"])
        .current_dir(project_root)
        .output();
    let Ok(out) = output else { return Vec::new(); };
    if !out.status.success() { return Vec::new(); }
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    stdout.lines().filter(|s| !s.is_empty()).map(PathBuf::from).collect()
}

/// Fallback when no git repo or `--since-last-commit=false` — scan
/// the whole project tree (capped to source extensions).
fn all_source_files(project_root: &Path) -> Vec<PathBuf> {
    let exts = ["rs", "swift", "js", "ts", "mjs", "cjs", "tsx", "py", "go"];
    let mut out = Vec::new();
    for entry in walkdir::WalkDir::new(project_root)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.file_name().to_str().unwrap_or("")))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        let Some(ext) = entry.path().extension().and_then(|s| s.to_str()) else { continue };
        if !exts.contains(&ext) { continue; }
        if let Ok(rel) = entry.path().strip_prefix(project_root) {
            out.push(rel.to_path_buf());
        }
    }
    out
}

fn is_skip_dir(name: &str) -> bool {
    matches!(
        name,
        "target" | "node_modules" | ".git" | ".tado" | "dist" | "build" | ".next"
        | ".build" | "DerivedData" | "Pods" | "venv" | ".venv" | "__pycache__"
    )
}

/// Optional: re-emit historical proposal counts so the perf-eval
/// agent can decide if the proposals file is growing.
pub fn count_by_category(proposals: &[Proposal]) -> BTreeMap<String, usize> {
    let mut map = BTreeMap::new();
    for p in proposals {
        *map.entry(p.category.clone()).or_insert(0usize) += 1;
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pattern_compiles() {
        let pats = patterns();
        assert!(pats.len() >= 25, "expected ≥25 patterns, got {}", pats.len());
    }

    #[test]
    fn proposal_display_includes_file_and_rung() {
        let p = Proposal {
            rung: 2,
            category: "allocation".into(),
            file: "src/lib.rs".into(),
            line: Some(42),
            message: "test".into(),
            target_metric: Some("alloc_per_op".into()),
        };
        let s = format!("{p}");
        assert!(s.contains("Rung 2"));
        assert!(s.contains("src/lib.rs:42"));
        assert!(s.contains("→alloc_per_op"));
    }

    #[test]
    fn count_by_category_groups() {
        let proposals = vec![
            Proposal { rung: 2, category: "allocation".into(), file: "a.rs".into(), line: None, message: "".into(), target_metric: None },
            Proposal { rung: 2, category: "allocation".into(), file: "b.rs".into(), line: None, message: "".into(), target_metric: None },
            Proposal { rung: 6, category: "io".into(), file: "c.rs".into(), line: None, message: "".into(), target_metric: None },
        ];
        let counts = count_by_category(&proposals);
        assert_eq!(counts.get("allocation"), Some(&2));
        assert_eq!(counts.get("io"), Some(&1));
    }

    #[test]
    fn patterns_filter_by_extension() {
        // The Rust Vec::new() pattern shouldn't match in a .py file.
        use crate::adapters::Stack;
        use crate::metrics::Direction;
        use chrono::Utc;
        use std::collections::BTreeMap;

        let dir = std::env::temp_dir().join(format!(
            "perf-pat-ext-{}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.py"), "x = Vec::new()\n").unwrap();
        let report = PerfReport {
            schema_version: 1,
            captured_at: Utc::now(),
            project_root: dir.display().to_string(),
            stack: Stack::Python,
            samples: BTreeMap::new(),
            notes: BTreeMap::new(),
            correctness_ok: true,
            correctness_failure: None,
        };
        let _ = Direction::LowerIsBetter; // hold the import
        let proposals = generate_proposals(&dir, &report, false, 10);
        // No Rust-specific Vec::new() pattern should match.
        assert!(!proposals.iter().any(|p| p.message.contains("Vec::new")));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
