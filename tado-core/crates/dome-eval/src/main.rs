//! `dome-eval` — measurable retrieval evaluation CLI for Dome.
//!
//! Subcommands:
//!
//! ```text
//! dome-eval replay   --vault <db.sqlite> [--since 7d]
//! dome-eval corpus   run     <corpus.yaml> [--json]
//! dome-eval corpus   validate <corpus.yaml>
//! dome-eval explain  --vault <db.sqlite>  --log-id <id>
//! ```
//!
//! All subcommands except `corpus run` require a real Dome vault (read-only).
//! `corpus run` boots an in-memory vault from the YAML fixture so it
//! can run in CI without touching the user's filesystem.

use anyhow::{anyhow, Context, Result};
use chrono::Duration;
use clap::{Args, Parser, Subcommand};
use dome_eval::{
    explain, format_summary, open_vault_readonly, replay::replay, Corpus, ExplainSeed, ReplayReport,
};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(
    name = "dome-eval",
    about = "Measurable retrieval evaluation for Tado's Dome second brain.",
    long_about = "Phase 2 of the Knowledge Catalog upgrade. Replay logged retrievals against a vault to measure regression, run a hand-labeled corpus as a CI gate, or explain why one ranked answer landed where it did.",
    version
)]
struct Cli {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Replay every retrieval_log row in the given window and report
    /// precision@k / recall@k / consumption rate.
    Replay(ReplayArgs),
    /// Corpus subcommands (run, validate).
    #[command(subcommand)]
    Corpus(CorpusCmd),
    /// Explain the rerank decision for one logged query.
    Explain(ExplainArgs),
}

#[derive(Args, Debug)]
struct ReplayArgs {
    /// Path to `<vault>/.bt/index.sqlite`.
    #[arg(long)]
    vault: PathBuf,
    /// Window: e.g. `7d`, `24h`, `30m`. Default: every row in the table.
    #[arg(long)]
    since: Option<String>,
    /// Emit machine-readable JSON instead of a one-line summary.
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand, Debug)]
enum CorpusCmd {
    /// Run a corpus YAML against an in-memory vault and exit non-zero on
    /// threshold regression.
    Run(CorpusRunArgs),
    /// Parse a corpus YAML and report any structural issues, without
    /// running it.
    Validate(CorpusRunArgs),
}

#[derive(Args, Debug)]
struct CorpusRunArgs {
    /// Path to the corpus fixture (YAML).
    fixture: PathBuf,
    /// Emit machine-readable JSON instead of a one-line summary.
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct ExplainArgs {
    /// Path to `<vault>/.bt/index.sqlite`.
    #[arg(long)]
    vault: PathBuf,
    /// `retrieval_log.log_id` to explain.
    #[arg(long = "log-id")]
    log_id: String,
    /// Emit machine-readable JSON instead of a human table.
    #[arg(long)]
    json: bool,
}

fn parse_since(input: &str) -> Result<Duration> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("empty --since"));
    }
    let (num_part, unit_part) = trimmed.split_at(
        trimmed
            .find(|c: char| !c.is_ascii_digit())
            .ok_or_else(|| anyhow!("--since needs a unit suffix (e.g. 7d, 24h, 30m)"))?,
    );
    let n: i64 = num_part
        .parse()
        .with_context(|| format!("--since '{}' has non-numeric prefix", trimmed))?;
    Ok(match unit_part {
        "s" => Duration::seconds(n),
        "m" => Duration::minutes(n),
        "h" => Duration::hours(n),
        "d" => Duration::days(n),
        "w" => Duration::weeks(n),
        other => {
            return Err(anyhow!(
                "--since unit '{}' not recognized — use s/m/h/d/w",
                other
            ));
        }
    })
}

fn run_replay(args: ReplayArgs) -> Result<ExitCode> {
    let conn = open_vault_readonly(&args.vault)?;
    let since = args
        .since
        .as_deref()
        .map(parse_since)
        .transpose()
        .context("parsing --since")?;
    let report = replay(&conn, since)?;
    print_replay(&report, args.json)?;
    Ok(ExitCode::SUCCESS)
}

fn print_replay(report: &ReplayReport, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(report)?);
        return Ok(());
    }
    println!(
        "{}  consumption_rate={:.3}  mean_latency_ms={:.1}",
        format_summary("replay", &report.aggregate),
        report.consumption_rate,
        report.mean_latency_ms
    );
    Ok(())
}

fn run_corpus_cmd(cmd: CorpusCmd) -> Result<ExitCode> {
    match cmd {
        CorpusCmd::Run(args) => {
            let corpus = Corpus::from_path(&args.fixture)?;
            let report = dome_eval::corpus::run_corpus(&corpus)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.one_line());
                if !report.passed {
                    eprintln!("FAILED thresholds:");
                    for f in &report.failures {
                        eprintln!("  - {}", f);
                    }
                }
            }
            Ok(if report.passed {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(2)
            })
        }
        CorpusCmd::Validate(args) => {
            let corpus = Corpus::from_path(&args.fixture)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&corpus)?);
            } else {
                println!(
                    "{} ({} docs, {} cases) OK",
                    corpus.name,
                    corpus.docs.len(),
                    corpus.cases.len()
                );
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn run_explain(args: ExplainArgs) -> Result<ExitCode> {
    let conn = open_vault_readonly(&args.vault)?;
    let (seed, rows) = explain(&conn, &args.log_id)?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({ "seed": seed, "rows": rows }))?
        );
    } else {
        print_explain_table(&seed, &rows);
    }
    Ok(ExitCode::SUCCESS)
}

fn print_explain_table(seed: &ExplainSeed, rows: &[dome_eval::ExplainRow]) {
    println!(
        "log_id={}  tool={}  actor={}  scope={}  consumed={}  latency_ms={}",
        seed.log_id, seed.tool, seed.actor_kind, seed.knowledge_scope, seed.was_consumed, seed.latency_ms
    );
    println!("query: {}", seed.query);
    println!();
    println!(
        "{:>4}  {:<36}  {:<8}  {:<7}  {:<7}  {:<8}  {:<10}  title",
        "rank", "doc_id", "scope", "fresh", "scope_m", "supersed", "confidence"
    );
    for r in rows {
        println!(
            "{:>4}  {:<36}  {:<8}  {:>7.3}  {:>7.3}  {:>8.3}  {:<10}  {}",
            r.rank,
            short(&r.doc_id, 36),
            short(&r.scope, 8),
            r.freshness,
            r.scope_match,
            r.supersede_penalty,
            r.confidence.map(|c| format!("{:.2}", c)).unwrap_or_else(|| "-".into()),
            r.title.as_deref().unwrap_or("(no title)")
        );
    }
}

fn short(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(n.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.cmd {
        Command::Replay(a) => run_replay(a),
        Command::Corpus(c) => run_corpus_cmd(c),
        Command::Explain(a) => run_explain(a),
    };
    match result {
        Ok(code) => code,
        Err(err) => {
            eprintln!("dome-eval: {err:#}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_since_handles_all_units() {
        assert_eq!(parse_since("7d").unwrap(), Duration::days(7));
        assert_eq!(parse_since("12h").unwrap(), Duration::hours(12));
        assert_eq!(parse_since("30m").unwrap(), Duration::minutes(30));
        assert_eq!(parse_since("45s").unwrap(), Duration::seconds(45));
        assert_eq!(parse_since("2w").unwrap(), Duration::weeks(2));
    }

    #[test]
    fn parse_since_rejects_unknown_unit() {
        assert!(parse_since("7y").is_err());
        assert!(parse_since("").is_err());
        assert!(parse_since("abc").is_err());
    }

    #[test]
    fn short_truncates_with_ellipsis() {
        assert_eq!(short("hello", 10), "hello");
        assert_eq!(short("hello world", 5), "hell…");
    }
}
