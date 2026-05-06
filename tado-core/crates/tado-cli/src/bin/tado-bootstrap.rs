//! tado-bootstrap — drive the four bootstrap actions per project.
//!
//! Subcommands:
//!   a2a       --project <name>
//!   team      --project <name>
//!   auto-mode --project <name>
//!   knowledge --project <name>
//!
//! Each subcommand spawns the corresponding one-shot bootstrap
//! agent tile in the running app — same effect as clicking
//! "Bootstrap …" from the project's `⋯` menu, but addressable
//! from a coordinator agent or any shell.

use clap::{Parser, Subcommand};
use serde_json::json;
use tado_cli::{control_client, print_response, OutputMode};

#[derive(Parser)]
#[command(name = "tado-bootstrap")]
#[command(about = "Coordinator-driven Tado bootstrap actions.", long_about = None)]
struct Cli {
    #[arg(long, global = true)]
    human: bool,
    #[arg(long, global = true)]
    toon: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Inject the Tado A2A CLI / MCP / events docs into the
    /// project's CLAUDE.md + AGENTS.md.
    A2a {
        #[arg(long)]
        project: String,
    },
    /// Inject team awareness into the project's docs.
    Team {
        #[arg(long)]
        project: String,
    },
    /// Configure Claude Code auto mode for the project.
    AutoMode {
        #[arg(long)]
        project: String,
    },
    /// Inject Tado's knowledge-layer (Dome) docs into the project.
    Knowledge {
        #[arg(long)]
        project: String,
    },
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);

    let (kind, project) = match cli.command {
        Command::A2a { project } => ("bootstrap.a2a", project),
        Command::Team { project } => ("bootstrap.team", project),
        Command::AutoMode { project } => ("bootstrap.auto-mode", project),
        Command::Knowledge { project } => ("bootstrap.knowledge", project),
    };

    let result = control_client::call(kind, json!({ "project": project }));

    let exit = match result {
        Ok(resp) => print_response(resp, mode),
        Err(e) => {
            eprintln!("{e}");
            if let control_client::ControlClientError::Server { data: Some(data), .. } = &e {
                eprintln!("{}", serde_json::to_string(data).unwrap_or_default());
            }
            1
        }
    };
    std::process::exit(exit);
}
