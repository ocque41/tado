//! tado-bootstrap — drive Codex bootstrap actions per project.
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
use tado_cli::{control_client, engine::normalize_workflow_engine, print_response, OutputMode};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser)]
#[command(name = "tado-bootstrap")]
#[command(about = "Coordinator-driven Tado bootstrap actions.", long_about = None)]
struct Cli {
    #[arg(long, global = true)]
    human: bool,
    #[arg(long, global = true)]
    toon: bool,
    #[arg(long, global = true, default_value = "codex")]
    engine: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Inject the Tado A2A CLI / MCP / events docs into the project's AGENTS.md.
    A2a {
        #[arg(long)]
        project: String,
    },
    /// Inject team awareness into the project's docs.
    Team {
        #[arg(long)]
        project: String,
    },
    /// Configure trusted Codex auto mode for the project.
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
    let engine = match normalize_workflow_engine(&cli.engine) {
        Ok(engine) => engine,
        Err(err) => {
            eprintln!("tado-bootstrap: {err}");
            std::process::exit(1);
        }
    };

    let (kind, project) = match cli.command {
        Command::A2a { project } => ("bootstrap.a2a", project),
        Command::Team { project } => ("bootstrap.team", project),
        Command::AutoMode { project } => ("bootstrap.auto-mode", project),
        Command::Knowledge { project } => ("bootstrap.knowledge", project),
    };

    if runtime_preferred() {
        let action = kind.strip_prefix("bootstrap.").unwrap_or(kind);
        let project_root = tado_cli::disk::resolve_project(&project).map(|p| p.root_path);
        let exit = match ensure_daemon(&profile_from_env(None)).and_then(|client| {
            client.call(
                "bootstrap.request",
                json!({
                    "action": action,
                    "project": project,
                    "project_root": project_root,
                    "engine": engine,
                }),
            )
        }) {
            Ok(resp) => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&resp.data.unwrap_or_else(|| json!({})))
                        .unwrap_or_else(|_| "{}".to_string())
                );
                0
            }
            Err(e) => {
                eprintln!("{e}");
                1
            }
        };
        std::process::exit(exit);
    }

    let result = control_client::call(kind, json!({ "project": project }));

    let exit = match result {
        Ok(resp) => print_response(resp, mode),
        Err(e) => {
            eprintln!("{e}");
            if let control_client::ControlClientError::Server {
                data: Some(data), ..
            } = &e
            {
                eprintln!("{}", serde_json::to_string(data).unwrap_or_default());
            }
            1
        }
    };
    std::process::exit(exit);
}

fn runtime_preferred() -> bool {
    ["TADO_PROFILE", "TADO_RUNTIME_SOCKET", "TADO_RUNTIME_ID"]
        .iter()
        .any(|key| {
            std::env::var_os(key)
                .map(|value| !value.is_empty())
                .unwrap_or(false)
        })
        || !std::path::Path::new("/tmp/tado-ipc/active-pid").exists()
}
