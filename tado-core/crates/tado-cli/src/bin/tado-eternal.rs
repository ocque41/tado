//! tado-eternal — drive the Eternal lifecycle from the CLI.
//!
//! Subcommands:
//!   propose --project <name> --feature <feature> --task "<text>"
//!           [--mode mega|sprint] [--engine claude|codex]
//!           --coordinator-todo-id <uuid> [--label <text>]
//!   status <run_id>
//!   crafted <run_id>
//!   accept <run_id> [--note "<text>"]
//!   reject <run_id> --reason "<text>" [--rebrief "<new brief>"]
//!   stop <run_id>
//!   list [--project <name>] [--state <state>]

use clap::{Parser, Subcommand};
use serde_json::json;
use tado_cli::{control_client, print_response, OutputMode};

#[derive(Parser)]
#[command(name = "tado-eternal")]
#[command(about = "Coordinator-driven Eternal lifecycle CLI.", long_about = None)]
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
    /// Create a new EternalRun, spawn the architect.
    Propose {
        #[arg(long)]
        project: String,
        #[arg(long)]
        feature: String,
        #[arg(long)]
        task: String,
        #[arg(long, default_value = "sprint")]
        mode: String,
        #[arg(long, default_value = "claude")]
        engine: String,
        #[arg(long = "coordinator-todo-id")]
        coordinator_todo_id: String,
        #[arg(long)]
        label: Option<String>,
    },
    /// Inspect a run's state.
    Status { run_id: String },
    /// Print the architect's `crafted.md`.
    Crafted { run_id: String },
    /// Accept the architect's plan and spawn the worker.
    Accept {
        run_id: String,
        #[arg(long)]
        note: Option<String>,
    },
    /// Reject the architect's plan, optionally rebriefing.
    Reject {
        run_id: String,
        #[arg(long)]
        reason: String,
        #[arg(long)]
        rebrief: Option<String>,
    },
    /// Request the worker to stop at the next sprint boundary.
    Stop { run_id: String },
    /// List runs.
    List {
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        state: Option<String>,
    },
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);

    let result = match cli.command {
        Command::Propose {
            project,
            feature,
            task,
            mode: run_mode,
            engine,
            coordinator_todo_id,
            label,
        } => {
            let mut payload = json!({
                "project": project,
                "feature": feature,
                "task": task,
                "mode": run_mode,
                "engine": engine,
                "coordinator_todo_id": coordinator_todo_id,
                "brief": task,
            });
            if let Some(l) = label {
                payload["label"] = json!(l);
            }
            control_client::call("eternal.propose", payload)
        }
        Command::Status { run_id } => {
            control_client::call("eternal.status", json!({ "run_id": run_id }))
        }
        Command::Crafted { run_id } => {
            control_client::call("eternal.crafted", json!({ "run_id": run_id }))
        }
        Command::Accept { run_id, note } => {
            let mut payload = json!({ "run_id": run_id });
            if let Some(n) = note {
                payload["note"] = json!(n);
            }
            control_client::call("eternal.accept", payload)
        }
        Command::Reject { run_id, reason, rebrief } => {
            let mut payload = json!({ "run_id": run_id, "reason": reason });
            if let Some(r) = rebrief {
                payload["rebrief"] = json!(r);
            }
            control_client::call("eternal.reject", payload)
        }
        Command::Stop { run_id } => {
            control_client::call("eternal.stop", json!({ "run_id": run_id }))
        }
        Command::List { project, state } => {
            let mut payload = json!({});
            if let Some(p) = project {
                payload["project"] = json!(p);
            }
            if let Some(s) = state {
                payload["state"] = json!(s);
            }
            control_client::call("eternal.list", payload)
        }
    };

    let exit = match result {
        Ok(resp) => print_response(resp, mode),
        Err(e) => {
            eprintln!("{e}");
            // Surface server-side error data when present so callers
            // can pattern-match on shape (state_mismatch + actual,
            // no_project + candidates, etc.).
            if let control_client::ControlClientError::Server { data: Some(data), .. } = &e {
                eprintln!("{}", serde_json::to_string(data).unwrap_or_default());
            }
            1
        }
    };
    std::process::exit(exit);
}
