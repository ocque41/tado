//! `sprint-suite` — measurable sprint-methodology evaluation for
//! Tado's Eternal Sprint step.
//!
//! Subcommands:
//!
//! ```text
//! sprint-suite detect    --project-root <path>
//! sprint-suite measure   --project-root <p> --run-dir <r> --output <sprint-report.json>
//! sprint-suite score     --report <sprint-report.json> --baseline <baseline.json>
//! sprint-suite propose   --project-root <p> --report <r> --output <sprint-proposals.md>
//! sprint-suite baseline  init   --report <r> --baseline <b>
//! sprint-suite baseline  update --report <r> --baseline <b>
//! sprint-suite explain   --report <sprint-report.json> [--metric <name>]
//! ```
//!
//! Stdout shape contracts (kept stable):
//! - `score` prints exactly one line that the bash gate parses:
//!     `SCORE: PASS composite=<n>` |
//!     `SCORE: REGRESSION delta=<d> hot=<sub> composite=<n>` |
//!     `SCORE: BASELINE-INIT composite=<n>` |
//!     `SCORE: NO-DATA-DETECTED`
//! - All other subcommands print human-readable output.
//!
//! Exit codes:
//! - 0 on PASS / BASELINE-INIT / NO-DATA-DETECTED / human completion.
//! - 2 on REGRESSION (so callers can use the exit code directly).
//! - 1 on internal error.

use anyhow::{Context, Result};
use chrono::Utc;
use clap::{Args, Parser, Subcommand};
use serde::Deserialize;
use sprint_suite::{
    baseline::{init_from, machine_drift, read_baseline, update_with, write_baseline},
    report::{read_report, write_report, SprintData, SprintReport, Weights},
    scoring::{score, ScoreVerdict},
};
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(
    name = "sprint-suite",
    about = "Measurable sprint-methodology evaluation for Tado's Eternal Sprint step.",
    version
)]
struct Cli {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Print whether `<project-root>/sprint-data.json` exists. One
    /// line: "data" or "no-data".
    Detect(DetectArgs),
    /// Read the latest entry from `sprint-data.json`, compute the
    /// SprintSuccessScore, write the report.
    Measure(MeasureArgs),
    /// Read a report + baseline, print the one-line `SCORE: ...`
    /// verdict. Exit 2 on regression.
    Score(ScoreArgs),
    /// Generate sprint_rules.txt refactor proposals from the most
    /// recent report. Writes a markdown file.
    Propose(ProposeArgs),
    /// Manage the per-project baseline file.
    #[command(subcommand)]
    Baseline(BaselineCmd),
    /// Print a human-readable per-component breakdown for one report.
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
    #[arg(long, default_value_t = 8)]
    cap: usize,
}

#[derive(Subcommand, Debug)]
enum BaselineCmd {
    Init(BaselineIoArgs),
    Update(BaselineIoArgs),
}

#[derive(Args, Debug)]
struct BaselineIoArgs {
    #[arg(long)]
    report: PathBuf,
    #[arg(long)]
    baseline: PathBuf,
}

#[derive(Args, Debug)]
struct ExplainArgs {
    #[arg(long)]
    report: PathBuf,
}

/// Wire-format for `sprint-data.json`. Either a single object (one
/// sprint) or an array (history — the most recent entry is scored).
/// The architect generates this file; the worker appends to it
/// after each EVAL.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum SprintDataFile {
    Single(SprintDataEntry),
    Many(Vec<SprintDataEntry>),
}

#[derive(Debug, Deserialize)]
struct SprintDataEntry {
    #[serde(flatten)]
    data: SprintData,
    /// Optional override of the default weights, e.g. when the team
    /// agrees to penalize bugs harder than the original prompt.
    #[serde(default)]
    weights: Option<Weights>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let res = match cli.cmd {
        Command::Detect(a) => cmd_detect(a),
        Command::Measure(a) => cmd_measure(a),
        Command::Score(a) => cmd_score(a),
        Command::Propose(a) => cmd_propose(a),
        Command::Baseline(BaselineCmd::Init(a)) => cmd_baseline_init(a),
        Command::Baseline(BaselineCmd::Update(a)) => cmd_baseline_update(a),
        Command::Explain(a) => cmd_explain(a),
    };
    match res {
        Ok(code) => code,
        Err(e) => {
            eprintln!("sprint-suite error: {e:#}");
            ExitCode::from(1)
        }
    }
}

fn cmd_detect(args: DetectArgs) -> Result<ExitCode> {
    let path = args.project_root.join("sprint-data.json");
    if path.exists() {
        println!("data");
    } else {
        println!("no-data");
    }
    Ok(ExitCode::from(0))
}

fn cmd_measure(args: MeasureArgs) -> Result<ExitCode> {
    let data_path = args.project_root.join("sprint-data.json");
    if !data_path.exists() {
        // Treat as a free pass — `score` will translate the missing
        // report into NO-DATA-DETECTED.
        eprintln!("sprint-suite: {} missing — measurement skipped", data_path.display());
        return Ok(ExitCode::from(0));
    }
    let raw = fs::read(&data_path).with_context(|| format!("reading {}", data_path.display()))?;
    let parsed: SprintDataFile = serde_json::from_slice(&raw)
        .with_context(|| format!("parsing {}", data_path.display()))?;
    let entry = match parsed {
        SprintDataFile::Single(e) => e,
        SprintDataFile::Many(many) => many
            .into_iter()
            .last()
            .with_context(|| format!("{} array is empty", data_path.display()))?,
    };
    let weights = entry.weights.clone().unwrap_or_default();
    let parts = entry.data.components(&weights);
    let composite: f64 = parts.iter().map(|(_, v)| v).sum();
    let notes = parts
        .iter()
        .map(|(name, v)| format!("{name}: {v:.3}"))
        .collect::<Vec<_>>();

    // Hash the rules file if present so future propose rounds can
    // tell when the rules changed between iterations.
    let rules_path = args.project_root.join("sprint_rules.txt");
    let rules_file_hash = if rules_path.exists() {
        let bytes = fs::read(&rules_path).ok();
        bytes.map(|b| simple_hash(&b))
    } else {
        None
    };

    let report = SprintReport {
        schema_version: 1,
        captured_at: Utc::now(),
        project_root: args.project_root.to_string_lossy().into_owned(),
        data: entry.data,
        weights,
        composite,
        notes,
        rules_file_hash,
    };
    write_report(&args.output, &report).with_context(|| {
        format!("writing report to {}", args.output.display())
    })?;
    let _ = args.run_dir; // run_dir is reserved for future per-run scratch
    println!(
        "measured composite={:.3} → {}",
        composite,
        args.output.display()
    );
    Ok(ExitCode::from(0))
}

fn cmd_score(args: ScoreArgs) -> Result<ExitCode> {
    if !args.report.exists() {
        // No report = no measurement = free pass. Mirrors perf-suite's
        // NO-STACK-DETECTED contract.
        println!("SCORE: NO-DATA-DETECTED");
        return Ok(ExitCode::from(0));
    }
    let report = read_report(&args.report)
        .with_context(|| format!("reading report at {}", args.report.display()))?;
    let baseline = read_baseline(&args.baseline)
        .with_context(|| format!("reading baseline at {}", args.baseline.display()))?;

    if let Some(b) = baseline.as_ref() {
        if machine_drift(b) && std::env::var("TADO_SPRINT_ALLOW_DRIFT").as_deref() != Ok("1") {
            eprintln!(
                "sprint-suite: baseline machine_class drift (set TADO_SPRINT_ALLOW_DRIFT=1 to override)"
            );
        }
    }

    let verdict = score(&report, baseline.as_ref())?;
    println!("{}", verdict.one_line());
    let exit = match verdict {
        ScoreVerdict::Regression { .. } => ExitCode::from(2),
        _ => ExitCode::from(0),
    };
    Ok(exit)
}

fn cmd_propose(args: ProposeArgs) -> Result<ExitCode> {
    let report = read_report(&args.report)
        .with_context(|| format!("reading report at {}", args.report.display()))?;
    let rules_path = args.project_root.join("sprint_rules.txt");
    let rules_present = rules_path.exists();
    let mut md = String::new();
    md.push_str("# Sprint-rules refactor proposals\n\n");
    md.push_str(&format!(
        "Composite this iteration: **{:.3}** (cap {} proposals)\n\n",
        report.composite, args.cap
    ));
    md.push_str(&format!(
        "Rules file: `{}`{}\n\n",
        rules_path.display(),
        if rules_present { "" } else { " (missing — write one before proposing)" }
    ));

    let mut proposals: Vec<(&str, &str)> = Vec::new();
    let bugs = report.data.bugs_found_after_sprint;
    let velocity = report.data.velocity_ratio();
    let reviews = report.data.code_review_passes;
    let sat = report.data.developer_satisfaction_score;

    if bugs > 0.0 {
        proposals.push((
            "bugs:two-reviewers-on-high-risk",
            "Add a rule: high-risk modules require TWO reviewers before merge. Bugs found post-sprint > 0 means review coverage is too thin somewhere.",
        ));
        proposals.push((
            "bugs:require-tests-on-touched-files",
            "Add a rule: any PR that touches a file without a corresponding test must add one in the same PR. Drives bug-density down via locked-in coverage.",
        ));
    }
    if velocity < 0.85 {
        proposals.push((
            "velocity:split-tasks-larger-than-5pts",
            "Add a rule: split any task larger than 5 points into sub-tasks. Velocity below 85% of plan often signals over-large tasks stalling at the line.",
        ));
        proposals.push((
            "velocity:carry-over-cap",
            "Add a rule: max 1 carryover ticket per sprint — anything else gets returned to backlog. Forces honest planning instead of perpetual rollover.",
        ));
    }
    if reviews < 8.0 {
        proposals.push((
            "reviews:async-review-window",
            "Add a rule: every PR has a 24-hour async-review window before sync escalation. Often raises code_review_passes by removing the bottleneck of waiting for one specific reviewer.",
        ));
    }
    if sat < 3.5 {
        proposals.push((
            "sat:standup-only-for-blocked",
            "Add a rule: daily standup runs only for tasks marked Blocked. Cuts meeting drag, which is the #1 driver of low developer_satisfaction in this rubric.",
        ));
        proposals.push((
            "sat:protected-focus-blocks",
            "Add a rule: 2 hour protected focus blocks per developer per day, no meetings. Improves perceived agency without affecting any other metric.",
        ));
    }

    // Always include a rules-hygiene proposal so the worker has at
    // least one thing to try even when every component looks clean.
    proposals.push((
        "hygiene:retire-stale-rule",
        "Audit sprint_rules.txt for any rule that hasn't fired in the last 5 sprints and remove it. Stale rules dilute the methodology and become noise.",
    ));

    proposals.truncate(args.cap);

    md.push_str("## Proposals\n\n");
    for (id, body) in &proposals {
        md.push_str(&format!("### `{id}`\n\n{body}\n\n"));
    }

    if let Some(parent) = args.output.parent() {
        fs::create_dir_all(parent).ok();
    }
    fs::write(&args.output, md.as_bytes())
        .with_context(|| format!("writing proposals to {}", args.output.display()))?;
    println!(
        "wrote {} proposals → {}",
        proposals.len(),
        args.output.display()
    );
    Ok(ExitCode::from(0))
}

fn cmd_baseline_init(args: BaselineIoArgs) -> Result<ExitCode> {
    let report = read_report(&args.report)?;
    let baseline = init_from(&report, report.composite);
    write_baseline(&args.baseline, &baseline)?;
    println!("baseline init composite={:.3}", baseline.composite);
    Ok(ExitCode::from(0))
}

fn cmd_baseline_update(args: BaselineIoArgs) -> Result<ExitCode> {
    let report = read_report(&args.report)?;
    let existing = read_baseline(&args.baseline)?;
    let next = match existing {
        Some(prev) => update_with(&prev, &report, report.composite.max(prev.composite)),
        None => init_from(&report, report.composite),
    };
    write_baseline(&args.baseline, &next)?;
    println!(
        "baseline update composite={:.3} (machine_class={:?})",
        next.composite,
        next.machine_class.as_deref().unwrap_or("unknown")
    );
    Ok(ExitCode::from(0))
}

fn cmd_explain(args: ExplainArgs) -> Result<ExitCode> {
    let report = read_report(&args.report)?;
    println!("Sprint composite: {:.3}", report.composite);
    println!("Captured at:      {}", report.captured_at);
    println!("Project root:     {}", report.project_root);
    println!();
    println!("Inputs:");
    println!("  tickets_completed:            {}", report.data.tickets_completed);
    println!(
        "  points_completed / planned:   {} / {}",
        report.data.points_completed, report.data.total_points_planned
    );
    println!("  bugs_found_after_sprint:      {}", report.data.bugs_found_after_sprint);
    println!("  code_review_passes:           {}", report.data.code_review_passes);
    println!(
        "  developer_satisfaction_score: {}",
        report.data.developer_satisfaction_score
    );
    println!();
    println!("Components:");
    for note in &report.notes {
        println!("  {note}");
    }
    Ok(ExitCode::from(0))
}

fn simple_hash(bytes: &[u8]) -> String {
    // Fowler-Noll-Vo 1a — small enough to hand-roll, stable across
    // releases. Used only to detect rules-file changes between
    // iterations; not a security boundary.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}
