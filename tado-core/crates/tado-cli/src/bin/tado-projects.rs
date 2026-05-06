//! tado-projects — list / resolve project names → root paths.
//!
//! Read-only: hits `<storage-root>/projects.json` directly. Works
//! even when the Tado app is not running, as long as the index
//! file exists from a prior session.

use clap::{Parser, Subcommand};
use serde_json::json;
use tado_cli::{print_json, OutputMode};

#[derive(Parser)]
#[command(name = "tado-projects")]
#[command(about = "List or resolve Tado projects.", long_about = None)]
struct Cli {
    /// Pretty-print output for human reading.
    #[arg(long, global = true)]
    human: bool,
    /// AXI-style compact output (one tab-separated key/value
    /// per line), best for LLM consumption.
    #[arg(long, global = true)]
    toon: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List all known projects.
    List,
    /// Resolve a project name (case-insensitive). Exits non-zero
    /// when no project matches.
    Resolve {
        /// Project name (or substring).
        name: String,
    },
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);

    match cli.command {
        Command::List => {
            let entries = tado_cli::read_projects_index();
            let payload = entries
                .iter()
                .map(|e| {
                    json!({
                        "id": e.id,
                        "name": e.name,
                        "rootPath": e.root_path,
                        "createdAt": e.created_at,
                    })
                })
                .collect::<Vec<_>>();
            print_json(&json!(payload), mode);
        }
        Command::Resolve { name } => {
            match tado_cli::disk::resolve_project(&name) {
                Some(entry) => {
                    print_json(
                        &json!({
                            "id": entry.id,
                            "name": entry.name,
                            "rootPath": entry.root_path,
                            "createdAt": entry.created_at,
                        }),
                        mode,
                    );
                }
                None => {
                    eprintln!("error [no_match]: no project named '{}'", name);
                    std::process::exit(1);
                }
            }
        }
    }
}
