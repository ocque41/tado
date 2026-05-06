//! `perf-suite` — measurable performance evaluation for Tado's
//! Eternal Performance step.
//!
//! Subcommands:
//!
//! ```text
//! perf-suite detect    --project-root <path>
//! perf-suite measure   --project-root <path> --run-dir <path> --output <perf-report.json>
//! perf-suite score     --report <perf-report.json> --baseline <baseline.json>
//! perf-suite propose   --report <perf-report.json> --since-last-commit --output <perf-proposals.md>
//! perf-suite baseline  init   --report <r> --baseline <b>
//! perf-suite baseline  update --report <r> --baseline <b>
//! perf-suite explain   --report <perf-report.json> [--metric <name>]
//! ```
//!
//! Stdout shape contracts:
//! - `score` prints exactly one line that the bash gate parses:
//!     `PERF: PASS composite=<n>` |
//!     `PERF: REGRESSION delta=<d> hot=<sub> composite=<n>` |
//!     `PERF: BASELINE-INIT composite=<n>` |
//!     `PERF: NO-STACK-DETECTED`
//! - All other subcommands print human-readable output unless `--json`
//!   is passed (where applicable).
//!
//! Exit codes:
//! - 0 on PASS / BASELINE-INIT / NO-STACK-DETECTED / human-readable
//!   completion.
//! - 2 on REGRESSION (so CI can use the exit code directly).
//! - 1 on internal error (panic, IO, parse failure).

use anyhow::{Context, Result};
use chrono::Utc;
use clap::{Args, Parser, Subcommand};
use perf_suite::{
    adapters::{detect_adapter, detect_stack, Stack},
    baseline::{init_from, machine_class, machine_drift, read_baseline, update_with, write_baseline},
    proposal::{generate_proposals, write_proposals_md},
    report::PerfReport,
    scoring::{score, ScoreVerdict},
    MeasurementContext,
};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(
    name = "perf-suite",
    about = "Measurable performance evaluation for Tado's Eternal Performance step.",
    version
)]
struct Cli {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Print the detected stack to stdout (one line: rust|swift|node|python|go|polyglot|unknown).
    Detect(DetectArgs),
    /// Run the project's correctness gate, then measure all eight
    /// metrics. Writes the report to `--output`.
    Measure(MeasureArgs),
    /// Read a report + baseline, print the one-line PERF: ... verdict.
    /// Exit 2 on regression.
    Score(ScoreArgs),
    /// Generate refactor proposals from the latest diff and the
    /// report. Writes a markdown file.
    Propose(ProposeArgs),
    /// Manage the per-project baseline file.
    #[command(subcommand)]
    Baseline(BaselineCmd),
    /// Print a human-readable per-metric breakdown for one report.
    Explain(ExplainArgs),
}

#[derive(Args, Debug)]
struct DetectArgs {
    #[arg(long)]
    project_root: PathBuf,
}

#[derive(Args, Debug)]
struct MeasureArgs {
    #[arg(long)]
    project_root: PathBuf,
    #[arg(long)]
    run_dir: PathBuf,
    #[arg(long)]
    output: PathBuf,
    /// Skip the correctness gate. Use only when the gate is run
    /// elsewhere (e.g. by `perf-gate.sh` directly) so the report
    /// still records `correctness_ok: true`.
    #[arg(long)]
    skip_correctness: bool,
}

#[derive(Args, Debug)]
struct ScoreArgs {
    #[arg(long)]
    report: PathBuf,
    #[arg(long)]
    baseline: PathBuf,
}

#[derive(Args, Debug)]
struct ProposeArgs {
    #[arg(long)]
    project_root: PathBuf,
    #[arg(long)]
    report: PathBuf,
    #[arg(long)]
    output: PathBuf,
    /// When set, scan every source file under `--project-root`
    /// instead of just files in `git diff HEAD`. Useful for first-
    /// run / non-git workflows.
    #[arg(long)]
    all_files: bool,
    #[arg(long, default_value_t = 8)]
    cap: usize,
}

#[derive(Subcommand, Debug)]
enum BaselineCmd {
    /// Create the baseline file from the latest report.
    Init(BaselineRwArgs),
    /// Update the baseline file using the latest report (only
    /// best-of values move forward — see `baseline::update_with`).
    Update(BaselineRwArgs),
}

#[derive(Args, Debug)]
struct BaselineRwArgs {
    #[arg(long)]
    report: PathBuf,
    #[arg(long)]
    baseline: PathBuf,
}

#[derive(Args, Debug)]
struct ExplainArgs {
    #[arg(long)]
    report: PathBuf,
    /// Optional baseline. When provided, explain computes the
    /// normalized score per component + the composite contribution.
    #[arg(long)]
    baseline: Option<PathBuf>,
    #[arg(long)]
    metric: Option<String>,
    #[arg(long)]
    json: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.cmd {
        Command::Detect(a) => run_detect(a),
        Command::Measure(a) => run_measure(a),
        Command::Score(a) => run_score(a),
        Command::Propose(a) => run_propose(a),
        Command::Baseline(c) => run_baseline_cmd(c),
        Command::Explain(a) => run_explain(a),
    };
    match result {
        Ok(code) => code,
        Err(err) => {
            eprintln!("perf-suite: {err:#}");
            ExitCode::from(1)
        }
    }
}

fn run_detect(args: DetectArgs) -> Result<ExitCode> {
    let stack = detect_stack(&args.project_root);
    println!("{stack}");
    Ok(ExitCode::SUCCESS)
}

fn run_measure(args: MeasureArgs) -> Result<ExitCode> {
    let stack = detect_stack(&args.project_root);
    if matches!(stack, Stack::Unknown) {
        // Write an empty report so downstream tools have a stable file
        // to read, and emit the contract sentinel for the gate.
        let report = PerfReport {
            schema_version: 1,
            captured_at: Utc::now(),
            project_root: args.project_root.display().to_string(),
            stack,
            samples: BTreeMap::new(),
            notes: BTreeMap::new(),
            correctness_ok: true,
            correctness_failure: None,
        };
        report.write_to(&args.output)?;
        println!("PERF: NO-STACK-DETECTED");
        return Ok(ExitCode::SUCCESS);
    }

    let adapter = detect_adapter(&args.project_root)
        .with_context(|| format!("no adapter for stack {stack:?}"))?;
    let ctx = MeasurementContext {
        project_root: args.project_root.clone(),
        run_dir: args.run_dir.clone(),
        stack,
        per_metric_budget_secs: None,
    };

    let (correctness_ok, correctness_failure) = if args.skip_correctness {
        (true, None)
    } else {
        match adapter.correctness_gate(&ctx) {
            Ok(()) => (true, None),
            Err(e) => (false, Some(e.to_string())),
        }
    };

    if !correctness_ok {
        let report = PerfReport {
            schema_version: 1,
            captured_at: Utc::now(),
            project_root: args.project_root.display().to_string(),
            stack,
            samples: BTreeMap::new(),
            notes: BTreeMap::new(),
            correctness_ok: false,
            correctness_failure: correctness_failure.clone(),
        };
        report.write_to(&args.output)?;
        println!(
            "PERF: CORRECTNESS-FAILED {} {}",
            stack,
            correctness_failure.unwrap_or_else(|| "unknown".into())
        );
        return Ok(ExitCode::SUCCESS);
    }

    let (samples, notes) = adapter
        .measure(&ctx)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let report = PerfReport {
        schema_version: 1,
        captured_at: Utc::now(),
        project_root: args.project_root.display().to_string(),
        stack,
        samples,
        notes,
        correctness_ok: true,
        correctness_failure: None,
    };
    report.write_to(&args.output)?;
    Ok(ExitCode::SUCCESS)
}

fn run_score(args: ScoreArgs) -> Result<ExitCode> {
    let report = PerfReport::read_from(&args.report)?;
    if !report.correctness_ok {
        // Mirror the measure-time sentinel so downstream sees a
        // single contract.
        println!(
            "PERF: CORRECTNESS-FAILED {} {}",
            report.stack,
            report.correctness_failure.as_deref().unwrap_or("unknown")
        );
        return Ok(ExitCode::SUCCESS);
    }
    let baseline = read_baseline(&args.baseline)?;
    let verdict = score(&report, baseline.as_ref())?;
    println!("{}", verdict.one_line());
    Ok(match verdict {
        ScoreVerdict::Regression { .. } => ExitCode::from(2),
        _ => ExitCode::SUCCESS,
    })
}

fn run_propose(args: ProposeArgs) -> Result<ExitCode> {
    let report = PerfReport::read_from(&args.report)?;
    // `since_last_commit = true` (default) means scan only files in the
    // working-tree diff. The `--all-files` flag inverts this for the
    // first-run / non-git case.
    let since_last_commit = !args.all_files;
    let proposals = generate_proposals(&args.project_root, &report, since_last_commit, args.cap);
    write_proposals_md(&args.output, &proposals)?;
    println!("Wrote {} proposals to {}", proposals.len(), args.output.display());
    Ok(ExitCode::SUCCESS)
}

fn run_baseline_cmd(cmd: BaselineCmd) -> Result<ExitCode> {
    let (init_only, args) = match cmd {
        BaselineCmd::Init(a) => (true, a),
        BaselineCmd::Update(a) => (false, a),
    };
    let report = PerfReport::read_from(&args.report)?;
    if !report.correctness_ok {
        eprintln!("perf-suite: refusing to update baseline — correctness gate failed");
        return Ok(ExitCode::from(2));
    }
    let existing = read_baseline(&args.baseline)?;

    // Machine drift guard. If the baseline was recorded on apple-
    // silicon-macos and we're now on linux, refuse the update unless
    // the operator opts in via TADO_PERF_ALLOW_DRIFT=1. The gate's
    // ratchet assumption depends on same-machine measurements.
    if let Some(prior) = existing.as_ref() {
        if machine_drift(prior) && std::env::var("TADO_PERF_ALLOW_DRIFT").as_deref() != Ok("1") {
            eprintln!(
                "perf-suite: refusing to update baseline — machine class drift detected (baseline={}, current={}). Set TADO_PERF_ALLOW_DRIFT=1 to override or delete the baseline file to re-init.",
                prior.machine_class.as_deref().unwrap_or("unknown"),
                machine_class()
            );
            return Ok(ExitCode::from(2));
        }
    }

    let composite = match score(&report, existing.as_ref())? {
        ScoreVerdict::Pass { composite }
        | ScoreVerdict::BaselineInit { composite } => composite,
        ScoreVerdict::Regression { .. } => {
            eprintln!("perf-suite: refusing to update baseline — score regressed");
            return Ok(ExitCode::from(2));
        }
    };
    let new_baseline = match (init_only, existing) {
        (true, _) | (false, None) => init_from(&report, composite),
        (false, Some(b)) => update_with(&b, &report, composite),
    };
    write_baseline(&args.baseline, &new_baseline)?;
    println!("Baseline written: composite={composite:.3}");
    Ok(ExitCode::SUCCESS)
}

fn run_explain(args: ExplainArgs) -> Result<ExitCode> {
    let report = PerfReport::read_from(&args.report)?;
    let baseline = args.baseline.as_deref().and_then(|p| read_baseline(p).ok().flatten());

    if args.json {
        let mut out = serde_json::Map::new();
        out.insert("report".into(), serde_json::to_value(&report)?);
        if let Some(b) = baseline.as_ref() {
            out.insert("baseline".into(), serde_json::to_value(b)?);
            let registry = perf_suite::metrics::registry();
            let mut components = Vec::new();
            for (name, weight, _) in registry {
                let norm = report
                    .normalized_component(name, b.components.get(name).copied())
                    .map(|c| c.normalized);
                components.push(serde_json::json!({
                    "name": name,
                    "weight": weight,
                    "normalized": norm,
                }));
            }
            out.insert("components".into(), serde_json::Value::Array(components));
        }
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(ExitCode::SUCCESS);
    }

    println!(
        "Stack: {}   correctness_ok: {}   captured_at: {}",
        report.stack, report.correctness_ok, report.captured_at
    );
    if let Some(b) = baseline.as_ref() {
        println!(
            "Baseline composite: {:.3}   machine_class: {}",
            b.composite,
            b.machine_class.as_deref().unwrap_or("unknown")
        );
        if machine_drift(b) {
            println!(
                "⚠ machine_class drift: baseline={} current={}",
                b.machine_class.as_deref().unwrap_or("unknown"),
                machine_class()
            );
        }
    }
    if let Some(metric) = args.metric.as_deref() {
        if let Some(s) = report.samples.get(metric) {
            println!("{:24} value={:.4} unit={} adapter={}", metric, s.value, s.unit, s.adapter);
            if let Some(b) = baseline.as_ref() {
                if let Some(comp) = report.normalized_component(metric, b.components.get(metric).copied()) {
                    println!("  baseline={:.4}  normalized={:.3}", comp.baseline_value, comp.normalized);
                }
            }
        } else {
            println!("metric '{metric}' not in report");
        }
        return Ok(ExitCode::SUCCESS);
    }
    println!();
    println!("{:<24} {:>12} {:<16} {:<14} {:>9}", "metric", "value", "unit", "adapter", "norm");
    for (name, weight, _) in perf_suite::metrics::registry() {
        let s = match report.samples.get(name) {
            Some(s) => s,
            None => continue,
        };
        let norm = baseline
            .as_ref()
            .and_then(|b| report.normalized_component(name, b.components.get(name).copied()))
            .map(|c| format!("{:.3}", c.normalized))
            .unwrap_or_else(|| "—".into());
        println!(
            "{:<24} {:>12.4} {:<16} {:<14} {:>9}",
            name, s.value, s.unit, s.adapter, norm
        );
        let _ = weight;
    }
    Ok(ExitCode::SUCCESS)
}
