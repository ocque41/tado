//! tado-dispatch — drive the Dispatch lifecycle from the CLI.
//!
//! Same surface as tado-eternal, less complex: no mode picker
//! (Dispatch has only one shape), no completion marker.

use clap::{Parser, Subcommand};
use serde_json::json;
use tado_cli::{control_client, print_response, OutputMode};

#[derive(Parser)]
#[command(name = "tado-dispatch")]
#[command(about = "Coordinator-driven Dispatch lifecycle CLI.", long_about = None)]
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
    Propose {
        #[arg(long)]
        project: String,
        #[arg(long)]
        feature: String,
        #[arg(long)]
        task: String,
        #[arg(long = "coordinator-todo-id")]
        coordinator_todo_id: String,
        #[arg(long)]
        label: Option<String>,
    },
    Status { run_id: String },
    Crafted { run_id: String },
    Accept {
        run_id: String,
        #[arg(long)]
        note: Option<String>,
    },
    Reject {
        run_id: String,
        #[arg(long)]
        reason: String,
        #[arg(long)]
        rebrief: Option<String>,
    },
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
            coordinator_todo_id,
            label,
        } => {
            let mut payload = json!({
                "project": project,
                "feature": feature,
                "task": task,
                "coordinator_todo_id": coordinator_todo_id,
                "brief": task,
            });
            if let Some(l) = label {
                payload["label"] = json!(l);
            }
            control_client::call("dispatch.propose", payload)
        }
        Command::Status { run_id } => {
            control_client::call("dispatch.status", json!({ "run_id": run_id }))
        }
        Command::Crafted { run_id } => {
            control_client::call("dispatch.crafted", json!({ "run_id": run_id }))
        }
        Command::Accept { run_id, note } => {
            let mut payload = json!({ "run_id": run_id });
            if let Some(n) = note {
                payload["note"] = json!(n);
            }
            control_client::call("dispatch.accept", payload)
        }
        Command::Reject { run_id, reason, rebrief } => {
            let mut payload = json!({ "run_id": run_id, "reason": reason });
            if let Some(r) = rebrief {
                payload["rebrief"] = json!(r);
            }
            control_client::call("dispatch.reject", payload)
        }
        Command::List { project, state } => {
            let mut payload = json!({});
            if let Some(p) = project {
                payload["project"] = json!(p);
            }
            if let Some(s) = state {
                payload["state"] = json!(s);
            }
            control_client::call("dispatch.list", payload)
        }
    };

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
